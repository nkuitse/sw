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

sub _next {
    my ($self, $target, $tester) = @_;
    my ($sql, @params);
    if (!defined $target) {
        $sql = q{
            SELECT  t.next,
                    o.path,
                    x.path
            FROM    mon.tests    t,
                    main.objects o,
                    main.objects x
            WHERE   t.target = o.id
            AND     t.tester = x.id
            AND     t.next IS NOT NULL
        };
    }
    elsif (!defined $tester) {
        $sql = q{
            SELECT  t.next,
                    o.path,
                    x.path
            FROM    mon.tests    t,
                    main.objects o,
                    main.objects x
            WHERE   t.target = o.id
            AND     t.tester = x.id
            AND     o.path = ?
            AND     t.next IS NOT NULL
        };
        @params = ($target);
    }
    else {
        $sql = q{
            SELECT  t.next,
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
    my $dbh = $self->app->dbh;
    my $sth = $dbh->prepare($sql);
    $sth->execute(@params);
    my %out;
    while (my ($next, $opath, $xpath) = $sth->fetchrow_array) {
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
    $app->usage('next [-l] [TARGET [TEST]]') if @ARGV < 1 || @ARGV > 2;
    my $dbh = $app->dbh;
    my ($target, $tester) = @ARGV;
    my $out = $self->_next(@ARGV);
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

sub mon_schedule {
    my ($self) = @_;
    my $app = $self->app;
    $app->usage('schedule TIME TARGET TEST') if @ARGV != 3;
    my ($time, $target, $tester) = @ARGV;
    $time = time + dur2sec($time) if $time =~ s/^\+//;
    my $dbh = $app->dbh;
    my $sql = q{
        SELECT  t.id,
                o.id,
                x.id
        FROM    mon.tests t,
                objects   o,
                objects   x
        WHERE   t.target = o.id
        AND     t.tester = x.id
        AND     o.path = ?
        AND     x.path = ?
    };
    my $sth = $dbh->prepare($sql);
    $sth->execute($target, $tester);
    my ($t, $o, $x) = $sth->fetchrow_array;
    $sth->finish;
    my @params;
    if (defined $t) {
        $sql = q{
            UPDATE  mon.tests
            SET     next = ?
            WHERE   id = ?
        };
        @params = ($time, $t);
    }
    else {
        $o = $app->object($target)->{'id'};
        $x = $app->object($tester)->{'id'};
        $sql = q{
            INSERT INTO mon.tests
                (target, tester, state, next)
            VALUES
                (?, ?, ?, ?)
        };
        @params = ($o, $x, undef, $time);
    }
    $sth = $dbh->prepare($sql);
    $sth->execute(@params);
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
    my ($sql, @params);
    if (!defined $tester) {
        $sql = q{
            SELECT  s.status,
                    s.first,
                    s.last,
                    x.path
            FROM    mon.tests    t,
                    mon.states   s,
                    main.objects o,
                    main.objects x
            WHERE   t.target = o.id
            AND     t.tester = x.id
            AND     t.state  = s.id
            AND     o.path = ?
        };
        @params = ($target);
    }
    else {
        $sql = q{
            SELECT  s.status,
                    s.first,
                    s.last,
                    x.path
            FROM    mon.tests    t,
                    mon.states   s,
                    main.objects o,
                    main.objects x
            WHERE   t.target = o.id
            AND     t.tester = x.id
            AND     t.state  = s.id
            AND     o.path = ?
            AND     x.path = ?
        };
        @params = ($target, $tester);
    }
    my $sth = $dbh->prepare($sql);
    $sth->execute(@ARGV);
    if (my @row = $sth->fetchrow_array) {
        my ($code, $first, $last, $xpath) = @row;
        1;
    }
}

sub mon_run {
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
            s/^[%]\((.+)\)$/expand($1, \%var)/e;
        }
        open my $fh, '-|', @cmd or die;
        $select->add($fh);
        push @running, {
            'fh' => $fh,
            'target' => $o,
            'test' => $t,
            'result' => undef,
        };
    }
    while (@running) {
        my @ready = $select->can_read;
        foreach my $fh (@ready) {
            my ($test) = grep { $_->{'fh'} eq $fh } @running;
            my $out = <$fh>;
            if (defined $out) {
                chomp $out;
                $test->{'result'} = $1 if $out =~ /^(OK|ERR|WARN)/;
                push @finish, $test;
            }
            else {
                $select->remove($fh);
                $test->{'result'} = close($fh) ? 'OK' : 'ERR';
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
                $test->{'result'} = close($fh) ? 'OK' : 'ERR';
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
    my ($str, $var) = @_;
    my $h = $var;
    if ($str =~ s{^(\w+)}{}) {
        $h = $h->{$1} or die;
    }
    if ($str =~ s{^\.(\w+)}{}) {
        my $v = $h->{'properties'}{$1};
        die if !defined $v;
        return $v if !ref $v;
        return $v->[0] if ref($v) eq 'ARRAY';
        die;
    }
    else {
        return $h->{'properties'}{':name'};
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

1;
