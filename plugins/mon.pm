package App::sw::Plugin::mon;

use strict;
use warnings;

use Text::ParseWords;
use IO::Select;

{
    no warnings;
    *usage = *App::sw::main::usage;
}

my $usagestr = 'mon COMMAND [ARG...]';

sub new {
    my $cls = shift;
    bless { @_ }, $cls;
}

sub app { shift()->{'app'} }

sub commands {
    return (
        'mon' => \&mon,
    );
}

sub hooks { }

sub init {
    my ($self) = @_;
    my $app = $self->app;
    my $dbfile = $app->dbfile('mon');
    my $initialized = -e $dbfile;
    $app->attach('mon');
    $self->initdb($dbfile) if !$initialized;
}

sub mon {
    my $self = shift;
    usage($usagestr) if !@ARGV;
    my $subcmd = shift @ARGV;
    unshift @_, $self;
    goto &{ __PACKAGE__->can('mon_'.$subcmd) || usage($usagestr) };
}

sub mon_ls {
    my $self = shift;
    my $app = $self->app;
    my ($long);
    $app->getopts(
        'l|long' => \$long,
    );
}

sub next {
    my $self = shift;
    my $app = $self->app;
    my $dbh = $app->dbh;
    my @next = db_next($dbh, @_);
    my %out;
    foreach my $t (@next) {
        my ($next, $target, $tester) = @$t{qw(next target tester)};
        my $opath = App::sw::db_path($dbh, $target);
        my $xpath = App::sw::db_path($dbh, $tester);
        $out{$opath}{$xpath} = $next;
    }
    return \%out;
}

sub mon_next {
    my $self = shift;
    my $app = $self->app;
    my ($long);
    $app->getopts(
        'l|long' => \$long,
    );
    $app->usage('next [-l] [TARGET [TEST]]') if @ARGV > 2;
    my $dbh = $app->dbh;
    my ($target, $tester) = @ARGV;
    my $out = $self->next(@ARGV);
    foreach my $o (sort keys %$out) {
        my $xhash = $out->{$o};
        foreach my $x (sort keys %$xhash) {
            my $t = $xhash->{$x};
            my @out = ($t);
            push @out, $o if !defined $target;
            push @out, $x if !defined $tester;
            print join(' ', @out), "\n";
        }
    }
}

sub db_schedule_test {
    my ($dbh, $test, $time) = @_;
    my $tid = App::sw::db_oid($dbh, $test);
    my $sth = $dbh->prepare($dbh, 'UPDATE mon.tests SET next = ? WHERE id = ?');
    $sth->execute($time, $tid);
}

sub db_record_test_result {
    my ($dbh, $test, $status) = @_;
    my $tid = db_test_id($dbh, $test);
    my $state = eval { db_test_state($dbh, $test) };
    my $time = time;
    if (defined $state && $state->{'status'} eq $status) {
        my $sth = $dbh->prepare('UPDATE mon.states SET last = ? WHERE id = ?');
        $sth->execute($time, $state->{'id'});
    }
    else {
        my $sth = $dbh->prepare(q{
            INSERT INTO mon.states (test, status, first, last)
            VALUES  (?, ?, ?, ?)
        });
        $sth->execute($tid, $status, $time, $time);
        my $sid = $dbh->last_insert_id('', '', '', '');
        $sth = $dbh->prepare('UPDATE mon.tests SET state = ? WHERE id = ?');
        $sth->execute($sid, $tid);
    }
}

sub db_test_state {
    my $dbh = shift;
    my $test = db_test($dbh, @_);
    my $tid = db_test_id($dbh, $test);
    my $sth = $dbh->prepare(q{
        SELECT  s.*
        FROM    mon.tests t,
                mon.states s
        WHERE   t.state = s.id
        AND     t.id = ?
    });
    $sth->execute($tid);
    my $state = $sth->fetchrow_hashref;
    $sth->finish;
    if (!defined $state) {
        my ($opath, $xpath) = map { App::sw::db_path($dbh, $_) } @$test{qw(target tester)};
        die "test $xpath of $opath has no state";
    }
    return $state;
}

sub mon_schedule {
    my ($self) = @_;
    my $app = $self->app;
    $app->usage('schedule TIME TARGET TEST') if @ARGV != 3;
    my ($time, $target, $tester) = @ARGV;
    my $dbh = $app->dbh;
    my $test = db_test($dbh, $target, $tester) || db_create_test($dbh, $target, $tester);
    if ($time =~ s/^\+//) {
        $time = time + dur2sec($time);
    }
    elsif ($time !~ /^[0-9]+/) {
        $app->fatal("unrecognized time: $time");
    }
    db_schedule_test($test, $time);
}

sub mon_status {
    my $self = shift;
    my $app = $self->app;
    my ($long);
    $app->getopts(
        'l|long' => \$long,
    );
    $app->usage('status [-l] TARGET [TEST]') if @ARGV < 1 || @ARGV > 2;
    my ($target, $tester) = @ARGV;
    my $dbh = $app->dbh;
    my $test = db_test($dbh, $target, $tester) || $app->fatal("no such test: $target $tester");
    print join(' ', @$test{qw(first last status)}), "\n";
}

sub mon_tests {
    my ($self) = @_;
    my $app = $self->app;
    $app->getopts;
    $app->usage('tests TARGET [TEST...]') if !@ARGV;
    my $target = shift @ARGV;
    my @tests = $self->tests($target);
    1;
}

sub mon_run {
    my $self = shift;
    my $app = $self->app;
    $app->getopts;
    $app->usage('run TARGET [TEST...]') if !@ARGV;
    my @runners = $self->runners(@ARGV);
    $self->run(@runners);
    my $dbh = $app->dbh;
    foreach my $runner (@runners) {
        my ($t, $o, $x, $status) = @$runner{qw(test target tester status)};
        my ($opath, $xpath) = map { $app->object($_)->{'path'} } ($o, $x);
        db_record_test_result($dbh, $t, $status);
        print join(' ', $status, $opath, $xpath), "\n";
    }
}

sub runners {
    my $self = shift;
    my $o = shift;
    my $app = $self->app;
    my $target = $app->object($o);
    my $oprops = $app->properties($o);
    my @tests = @_ ? (map { $self->test($target, $_) } @_) : ($self->tests($target));
    my @runners;
    foreach my $test (@tests) {
        my $x = $test->{'tester'};
        my $xprops = $app->properties($x);
        my $cmd = $xprops->{'cmd'} || die;
        die if @$cmd > 1;
        $cmd = $cmd->[0];
        my @cmd = shellwords($cmd);
        my %var = (
            'target' => $oprops,
            'test' => $xprops,
        );
        for (@cmd) {
            s/^[%]\((.+)\)$/$self->expand($1, \%var)/e;
        }
        push @runners, {
            'test' => $test,
            'target' => $target,
            'tester' => $app->object($x),
            'command' => \@cmd,
        }
    }
    return @runners;
}

sub run {
    my $self = shift;
    my $select = IO::Select->new;
    my (@running, @finish, @done);
    foreach my $runner (@_) {
        my @cmd = @{ $runner->{'command'} };
        open my $fh, '-|', @cmd or die;
        $select->add($fh);
        $runner->{'fh'} = $fh;
        $runner->{'status'} = undef;
        push @running, $runner;
    }
    while (@running) {
        my @ready = $select->can_read;
        foreach my $fh (@ready) {
            my ($test) = grep { $_->{'fh'} eq $fh } @running;
            my $out = <$fh>;
            if (defined $out) {
                chomp $out;
                $test->{'status'} = $1 if $out =~ /^(OK|ERR|WARN)/;
                push @finish, $test;
            }
            else {
                $select->remove($fh);
                $test->{'status'} = close($fh) ? 'OK' : 'ERR';
            }
            @running = grep { $_->{'fh'} ne $fh } @running;
        }
    }
    while (@finish) {
        my @ready = $select->can_read;
        foreach my $fh (@ready) {
            my ($test) = grep { $_->{'fh'} eq $fh } @finish;
            my $out = <$fh>;
            if (!defined $out) {
                $test->{'status'} = close($fh) ? 'OK' : 'ERR';
                @finish = grep { $_->{'fh'} ne $fh } @finish;
                push @done, $test;
            }
        }
    }
    return @done;
}

sub test {
    my ($self, $target, $tester) = @_;
    my $dbh = $self->app->dbh;
    return db_test($target, $tester);
}

sub tests {
    my ($self, $target) = @_;
    my $dbh = $self->app->dbh;
    return db_tests($dbh, $target);
}

sub old_mon_run {
    my $self = shift;
    my $app = $self->app;
    $app->getopts;
    $app->usage('run TARGET [TEST...]') if !@ARGV;
    my $o = shift @ARGV;
    my $target = $app->object($o);
    $target->{'properties'} = $app->properties($target);
    @ARGV = tests_for($target) if !@ARGV;
    my $select = IO::Select->new;
    my (@running, @finish, @done);
    foreach my $t (@ARGV) {
        my $test = $app->object($t);
        my $props = $test->{'properties'} = $app->properties($test);
        my $cmd = $props->{'cmd'} || die;
        die if @$cmd > 1;
        $cmd = $cmd->[0];
        my @cmd = shellwords($cmd);
        my %var = (
            'target' => $target,
            'test' => $test,
        );
        for (@cmd) {
            s/^[%]\((.+)\)$/$self->expand($1, \%var)/e;
        }
        open my $fh, '-|', @cmd or die;
        $select->add($fh);
        push @running, {
            'fh' => $fh,
            'target' => $o,
            'test' => $t,
            'status' => undef,
        };
    }
    while (@running) {
        my @ready = $select->can_read;
        foreach my $fh (@ready) {
            my ($test) = grep { $_->{'fh'} eq $fh } @running;
            my $out = <$fh>;
            if (defined $out) {
                chomp $out;
                $test->{'status'} = $1 if $out =~ /^(OK|ERR|WARN)/;
                push @finish, $test;
            }
            else {
                $select->remove($fh);
                $test->{'status'} = close($fh) ? 'OK' : 'ERR';
            }
            @running = grep { $_->{'fh'} ne $fh } @running;
        }
    }
    while (@finish) {
        my @ready = $select->can_read;
        foreach my $fh (@ready) {
            my ($test) = grep { $_->{'fh'} eq $fh } @finish;
            my $out = <$fh>;
            if (!defined $out) {
                $test->{'status'} = close($fh) ? 'OK' : 'ERR';
                @finish = grep { $_->{'fh'} ne $fh } @finish;
                push @done, $test;
            }
        }
    }
    foreach (@done) {
        my ($o, $t, $result) = @$_{qw(target test result)};
        print join(' ', $result, $o, $t), "\n";
        # TODO update status
    }
}

sub expand {
    my ($self, $str, $var) = @_;
    my $h = $var;
    my ($opart, $ppart) = split /\./, $str;
    my ($bpart, @zparts) = split /(?=\[\@)/, $opart;
    my $app = $self->app;
    my $hprops;
    if (@zparts) {
        # target[@host]
        $h = $app->object($h->{$bpart}) or die;
        foreach (@zparts) {
            s/^\[(\@.+)\]$// or die;
            my $os = $h->{$1} or die;
            die if @$os != 1;
            ($h) = @$os;
        }
        $hprops = $app->properties($h);
    }
    else {
        $hprops = $h->{$bpart} or die "unexpandable: $str";
    }
    if (defined $ppart) {
        my $v = $hprops->{$ppart};
        die if !defined $v;
        return $v if !ref $v;
        return $v->[0] if ref($v) eq 'ARRAY';
        die;
    }
    else {
        return $hprops->{':name'};
    }
}

sub tests_for {
    my ($obj) = @_;
    my @props = @{ $obj->{'properties'}{'@test'} || [] };
    return map { $_->{'path'} } @props;
}

sub initdb {
    my ($self, $dbfile) = @_;
    my $app = $self->app;
    my $dbh = $app->dbh;
    my @sql = split /;\n/, q{
        CREATE TABLE mon.tests (
            id      INTEGER PRIMARY KEY,
            target  INTEGER NOT NULL, /* REFERENCES main.objects(id) */
            tester  INTEGER NOT NULL, /* REFERENCES main.objects(id) */
            state   INTEGER     NULL REFERENCES states(id),
            next    INTEGER     NULL
        );
        CREATE INDEX mon.tests_target_tester ON tests(target, tester);
        CREATE INDEX mon.tests_next          ON tests(next);
        /**********************************************************************/
        CREATE TABLE mon.states (
            id      INTEGER PRIMARY KEY,
            test    INTEGER NOT NULL,
            status  VARCHAR NOT NULL,
            first   INTEGER NOT NULL,
            last    INTEGER NOT NULL
        );
        CREATE INDEX mon.states_test       ON states(test);
        CREATE INDEX mon.states_test_first ON states(test, first);
        CREATE INDEX mon.states_test_last  ON states(test, last);
    };
    foreach (@sql) {
        #print STDERR $_, "\n...";
        $dbh->do($_);
        #print STDERR "OK\n";
    }
}

sub dur2sec {
    my %u2s = qw(
        y   31557600
        w     604800
        d      86400
        h       3600
        m         60
        s          1
    );
    my $t = shift;
    my $s = 0;
    while ($t =~ s/^(\d+)([ywdhms])//) {
        $s += $1 * $u2s{$2};
    }
    $s += $t if $t =~ /^\d+$/;
    return $s;
}

# --- Database operations

sub db_test {
    my $dbh = shift;
    die if !@_;
    my ($sth, @params);
    my ($o, $x);
    if (@_ == 1) {
        my ($t) = @_;
        return $_[0] if ref $t;  # db_test($t);
        die if $t !~ /^[0-9]+$/;
        $sth = $dbh->prepare('SELECT * FROM mon.tests WHERE id = ?');
        @params = ($t);
    }
    elsif (@_ == 2) {
        ($o, $x) = @_;  # db_test($o, $x);
        $o = App::sw::db_oid($dbh, $o);
        $x = App::sw::db_oid($dbh, $x);
        $sth = $dbh->prepare('SELECT * FROM mon.tests WHERE target = ? AND tester = ?');
        @params = ($o, $x);
    }
    $sth->execute(@params);
    my $test = $sth->fetchrow_hashref;
    $sth->finish;
    return $test if $test;
    die "no such test: $_[0]" if @_ == 1;
    return;
}

sub db_test_id {
    my ($dbh, $t) = @_;
    return $t->{'id'} if ref $t;
    return $t if $t =~ /^[0-9]+$/;
    return db_test($t)->{'id'};
}

sub db_tests {
    my ($dbh, $o) = @_;
    my ($sth, @params);
    if (defined $o) {
        # db_tests($dbh, $target);
        my $oid = App::sw::db_oid($dbh, $o);
        $sth = $dbh->prepare('SELECT * FROM mon.tests WHERE target = ?');
        @params = ($oid);
    }
    else {
        $sth = $dbh->prepare('SELECT * FROM mon.tests');
    }
    my @tests;
    $sth->execute(@params);
    while (my $test = $sth->fetchrow_hashref) {
        push @tests, $test;
    }
    return @tests;
}

sub db_create_test {
    my ($dbh, $o, $x) = @_;
    my $oid = App::sw::db_oid($dbh, $o);
    my $xid = App::sw::db_oid($dbh, $x);
    my $sth = $dbh->prepare('INSERT INTO mon.tests (target, tester, status) VALUES (?, ?, ?)');
    $sth->execute($oid, $xid, 'UNKN');
    my $tid = $dbh->last_insert_id('', '', '', '');
    return {
        'id' => $tid,
        'target' => $oid,
        'tester' => $xid,
        'first' => undef,
        'last' => undef,
        'status' => 'UNKN',
    };
}

sub db_next {
    my ($dbh, $target, $tester) = @_;
    my ($sql, @params);
    if (!defined $target) {
        $sql = q{
            SELECT  t.id,
                    t.next,
                    o.path,
                    x.path
            FROM    mon.tests    t,
                    main.objects o,
                    main.objects x
            WHERE   t.target = o.id
            AND     t.tester = x.id
            AND     t.next IS NOT NULL
            ORDER   BY t.next
        };
    }
    elsif (!defined $tester) {
        $sql = q{
            SELECT  t.id,
                    t.next,
                    o.path,
                    x.path
            FROM    mon.tests    t,
                    main.objects o,
                    main.objects x
            WHERE   t.target = o.id
            AND     t.tester = x.id
            AND     o.path = ?
            AND     t.next IS NOT NULL
            ORDER   BY t.next
        };
        @params = ($target);
    }
    else {
        $sql = q{
            SELECT  t.id,
                    t.next,
                    o.path,
                    x.path
            FROM    mon.tests    t,
                    main.objects o,
                    main.objects x
            WHERE   t.target = o.id
            AND     t.tester = x.id
            AND     o.path = ?
            AND     x.path = ?
            AND     t.next IS NOT NULL
        };
        @params = ($target, $tester);
    }
    my $sth = $dbh->prepare($sql);
    $sth->execute(@params);
    my @out;
    while (my ($id, $next, $o, $x) = $sth->fetchrow_array) {
        push @out, { 'id' => $id, 'next' => $next, 'target' => $o, 'tester' => $x };
    }
    return @out;
}

1;
