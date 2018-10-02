#!/usr/bin/perl

use strict;
use warnings;

use Cwd;
use DBI;
use Getopt::Long
    qw(:config posix_default gnu_compat require_order bundling no_ignore_case);

sub fatal;
sub usage;

my $root = '/site/var/sw';
my $dbfile = $ENV{'SW_DBFILE'} || dbfile();
my $dbh;

@ARGV = qw(shell) if !@ARGV;
for ($ARGV[0]) {
    unshift(@ARGV, 'ls'  ), last if s{^[@]}{};
    unshift(@ARGV, 'find'), last if m{^/};
}

my $cmd = shift @ARGV;
&{ __PACKAGE__->can('cmd_'.$cmd) or usage };

# --- Command handlers

sub cmd_init {
    my $dir = @ARGV ? shift @ARGV : cwd();
    $dir = "$root/$dir" if $dir !~ m{^[./]};
    my $dbfile = $dir . '/sw.db';
    -d $dir or mkdir $dir or fatal "mkdir $dir: $!";
    initdb($dbfile);
    print STDERR "initialized: $dir\n";
}

sub cmd_machines {
    getopts();
    opendb($dbfile);
    if (@ARGV == 0) {
        # List machines
        my @machines = machines();
        print $_->{'name'}, "\n" for @machines;
    }
    else {
        usage('machines [-d DB]');
    }
}

sub cmd_ls {
    my ($long);
    getopts(
        'l|long' => \$long,
    );
    opendb($dbfile);
    if (@ARGV == 1) {
        # List software on the given machine
        my $mach = shift @ARGV;
        my @insts = instances_on_machine($mach);
        foreach my $instance (@insts) {
            my ($name, $qual, $vers) = @$instance{qw(name qualifier version)};
            $name .= ':' . $qual if defined $qual;
            $name .= ' ' . $vers if defined $vers;
            print $name, "\n";
        }
    }
    else {
        my $sql = q{
            SELECT  m.name,
                    a.name,
                    i.qualifier,
                    i.version
            FROM    machines m,
                    instances i,
                    applications a
            WHERE   i.machine = m.id
            AND     i.application = a.id
            ORDER   BY m.name, a.name, i.qualifier
        };
        my $sth = $dbh->prepare($sql);
        $sth->execute;
        my @rows = ( [qw(machine application version)] );

        while (my ($mach, $app, $qual, $vers) = $sth->fetchrow_array) {
            $app .= ':' . $qual if defined $qual;
            push @rows, [$mach, $app, $vers // '--'];
        }
        my @maxlen = (0, 0, 0);
        foreach my $row (@rows) {
            foreach my $i (0..2) {
                my $len = length $row->[$i];
                $maxlen[$i] = $len if $len > $maxlen[$i];
            }
        }
        splice @rows, 1, 0, [map { '-' x $_ } @maxlen];
        my $format = join('  ', map { "%-${_}.${_}s" } @maxlen) . "\n";
        foreach (@rows) {
            printf $format, @$_;
        }
    }
}

sub cmd_export {
    getopts();
    opendb($dbfile);
    @ARGV = map { $_->{'name'} } machines() if !@ARGV;
    my $sql = q{
        SELECT  m.name,
                a.name,
                i.qualifier,
                i.version,
                p.key,
                p.value
        FROM    machines m
                INNER JOIN instances i ON m.id = i.machine
                INNER JOIN applications a ON i.application = a.id
                LEFT OUTER JOIN instance_properties p ON p.instance = i.id
        WHERE   lower(m.name) = lower(?)
    };
    my $sth = $dbh->prepare($sql);
    foreach my $mach (@ARGV) {
        $sth->execute($mach);
        my ($app, $qual, $vers, $key, $val, %mach2inst);
        while (($mach, $app, $qual, $vers, $key, $val) = $sth->fetchrow_array) {
            $app .= ':' . $qual if defined $qual;
            $app .= ' ' . $vers if defined $vers;
            if (defined $key) {
                $mach2inst{$mach}{$app}{$key}{$val} = 1;
            }
            else {
                $mach2inst{$mach}{$app} ||= {};
            }
        }
        foreach $mach (sort keys %mach2inst) {
            print "machine $mach {\n";
            my $mhash = $mach2inst{$mach};
            foreach $app (sort keys %$mhash) {
                my $ihash = $mhash->{$app};
                print "  $app";
                my @keys = sort keys %$ihash;
                if (@keys) {
                    print " {\n";
                    foreach $key (@keys) {
                        my @vals = sort keys %{ $ihash->{$key} };
                        foreach $val (sort @vals) {
                            print "    $key $val\n";
                        }
                    }
                    print "  }\n";
                }
                else {
                    print "\n";
                }
            }
            print "}\n";
            1;
        }
    }
}

sub cmd_find {
    getopts();
    opendb($dbfile);
    if (@ARGV == 1) {
        my $arg = shift @ARGV;
        my $op = '=';
        if ($arg =~ m{^/(.+)/$}) {
            $op = 'REGEXP';
            $arg = $1;
        }
        my $sql = qq{
            SELECT  a.name,
                    m.name,
                    i.qualifier,
                    i.version
            FROM    applications a,
                    machines m,
                    instances i
            WHERE   a.id = i.application
            AND     m.id = i.machine
            AND     a.name $op ?
            ORDER   BY a.name, m.name, i.qualifier
        };
        my $sth = $dbh->prepare($sql);
        $sth->execute($arg);
        while (my ($aname, $mname, $iinst, $ivers) = $sth->fetchrow_array) {
            $aname .= ':' . $iinst if defined $iinst;
            print join(' ', grep { defined $_ } $mname, $aname, $ivers), "\n";
        }
    }
}

sub cmd_path {
    usage('path [-d DB] MACHINE APPLICATION [WHAT]') if @ARGV < 2 || @ARGV > 3;
    getopts();
    opendb($dbfile);
    my ($mach, $inst) = splice @ARGV, 0, 2;
    my @paths = instance_paths_on_machine($mach, $inst, @ARGV);
    foreach my $path (@paths) {
        if (@ARGV) {
            print $path->{'path'}, "\n";
        }
        else {
            printf "%-8.8s %s\n", $path->{'what'}, $path->{'path'};
        }
    }
}

sub cmd_port {
    my ($mach, $inst, $qual, $addr);
    getopts(
        'q|qualifier=s' => \$qual,
        'a|address=s' => \$addr,
    );
    usage('port [-d DB] [-i INSTANCE] [-a ADDRESS] MACHINE [APPLICATION]') if @ARGV < 1 || @ARGV > 2;
    opendb($dbfile);
    ($mach, $inst) = @ARGV;
    my @ports = instance_ports_on_machine($mach, $inst, $qual, $addr);
    foreach my $port (@ports) {
        my $addr = $port->{'address'};
        my @parts = defined $inst ? () : ($port->{'name'});
        push @parts, $port->{'port'};
        push @parts, '@'.$port->{'address'} if defined $port->{'address'};
        print "@parts\n";
    }
}

sub cmd_set {
    my $usage = 'set MACHINE (name|osname|osversion)=VALUE...';
    getopts() or usage($usage);;
    opendb($dbfile);
    my (@cols, @params);
    usage($usage) if @ARGV < 2;
    my $mach = shift @ARGV;
    foreach (argv2props()) {
        my ($k, $v) = @$_;
        usage($usage) if $k !~ /^(name|osname|osversion)$/;
        push @cols, $k;
        push @params, $v;
    }
    my $sql = sprintf q{
        UPDATE machines
        SET    %s
        WHERE  name = ?
    }, join(', ', map { "$_ = ?" } @cols);
    my $sth = $dbh->prepare($sql);
    $sth->execute(@params, $mach);
}

sub cmd_on {
    my $usage = 'on MACHINE [ls|add|rm|set] [ARG...]';
    getopts() or usage($usage);;
    opendb($dbfile);
    usage($usage) if @ARGV < 1;
    my $mach = shift @ARGV;
    @ARGV = qw(ls) if !@ARGV;
    my $verb = shift @ARGV;
    @_ = ($mach, @ARGV);
    goto &{ __PACKAGE__->can('on_machine_'.$verb) || usage($usage) };
}

sub cmd_add {
    usage('add MACHINE [KEY=VALUE...]') if @ARGV < 1;
    my $mach = shift @ARGV;
    opendb($dbfile);
    my $sth = $dbh->prepare(q{
        INSERT INTO machines (name, osname, osversion)
        VALUES               (?,    ?,      ?        )
    });
    my @props = argv2props();
    my %prop;
    foreach (@props) {
        my ($k, $v) = @$_;
        push @{ $prop{$k} ||= [] }, $v;
    }
    my ($osname, $osversion, @etc);
    ($osname, @etc) = @{ delete $prop{'osname'} || [] };
    fatal "a machine can have only one osname\n" if @etc;
    ($osversion, @etc) = @{ delete $prop{'osversion'} || [] };
    fatal "a machine can have only one osversion\n" if @etc;
    fatal "unrecognized properties for machine $mach: ", join(' ', keys %prop)
        if keys %prop;
    $sth->execute($mach, $osname, $osversion);
}

# --- Other functions

sub dbfile {
    return "$root/sw.db";
}

sub opendb {
    my ($dbfile) = @_;
    if (!defined $dbh) {
        $dbh = DBI->connect("dbi:SQLite:dbname=$dbfile", '', '');
        $dbh->{RaiseError} = 1;
    }
}

sub machines {
    my $sth = $dbh->prepare(q{
        SELECT  *
        FROM    machines
        ORDER   BY name
    });
    $sth->execute;
    my @machs;
    while (my $mach = $sth->fetchrow_hashref) {
        push @machs, $mach;
    }
    return @machs;
}

sub on_machine_ls {
    my ($mach) = @_;
    my @apps = instances_on_machine($mach);
    foreach my $inst (@apps) {
        my ($name, $qual, $version) = @$inst{qw(name qualifier version)};
        $name .= ':' . $qual if defined $qual;
        $name .= ' ' . $version if defined $version;
        print $name, "\n";
        next;
        my @parts = ($name);
        push @parts, '#'.$qual if defined $qual;
        push @parts, $version if defined $version;
        print "@parts\n";
    }
}

sub on_machine_add {
    my $usage = 'on MACHINE add APPLICATION[:QUALIFIER] [KEY=VALUE...]';
    usage($usage) if @_ < 2;
    opendb($dbfile);
    # --- Parse arguments
    my $mach = shift;
    my ($app, $qual) = appqual(shift());
    my @props = argv2props(@_);
    my ($vers) = map { $_->[1] } grep { $_->[0] eq 'version' } @props;
    @props = grep { $_->[0] ne 'version' } @props;
    # --- Get the machine ID
    my $sth_machine = $dbh->prepare(q{SELECT id FROM machines WHERE lower(name) = lower(?)});
    $sth_machine->execute($mach);
    my ($mid) = $sth_machine->fetchrow_array;
    fatal "no such machine: $mach" if !defined $mid;
    # --- Get the application ID
    my $sth_application = $dbh->prepare(q{SELECT id FROM applications WHERE lower(name) = lower(?)});
    $sth_application->execute($app);
    my ($aid) = $sth_application->fetchrow_array;
    if (!defined $aid) {
        $sth_application = $dbh->prepare(q{INSERT INTO applications (name) VALUES (?)});
        $sth_application->execute($app);
        $aid = $dbh->last_insert_id("","","","");
    }
    # --- Insert the instance
    my $sth_install = $dbh->prepare(q{INSERT OR IGNORE INTO instances (machine, application, qualifier, version) VALUES (?, ?, ?, ?)});
    $sth_install->execute($mid, $aid, $qual, $vers);
    my $iid = $dbh->last_insert_id("","","","");
    # --- Insert the specified properties
    if (@props) {
        my $sql_props = q{
            INSERT OR IGNORE INTO instance_properties
                    (instance, key, value)
        };
        my (@values, @params);
        foreach (@props) {
            push @values, q{
                    (?,         ?,   ?)
            };
            push @params, ($iid, @$_);
        }
        substr($values[0], 12, 6) = 'VALUES';
        $sql_props .= join(",\n", @values);
        my $sth_props = $dbh->prepare($sql_props);
        $sth_props->execute(@params);
    }
}

sub appqual {
    my ($app, $qual) = @_;
    $qual = $1 if $app =~ s{:([^:]+)$}{};
    return ($app, $qual);
}

sub appqual2str {
    my ($app, $qual) = @_;
    $app .= ':' . $qual if defined $qual;
    return $app;
}

sub on_machine_add_old {
    my ($mach) = @_;
    my $usage = 'on MACHINE add APPLICATION[:QUALIFIER] [version=VALUE]';
    usage($usage) if @_ != 2;
    my $app = shift;
    my ($qual, $vers);
    $qual = $1 if $app =~ s{:([^:]+)$}{};
    if (@_ == 1) {
        usage($usage) if shift(@_) !~ /^version=(.+)$/;
        $vers = $1;
    }
    opendb($dbfile);
    my $sth_machine = $dbh->prepare(q{SELECT id FROM machines WHERE lower(name) = lower(?)});
    my $sth_application = $dbh->prepare(q{SELECT id FROM applications WHERE lower(name) = lower(?)});
    my $sth_install = $dbh->prepare(q{
        INSERT OR IGNORE INTO instances
                (machine, application, qualifier, version)
        VALUES  (?,       ?,           ?,        ?      )
    });
    $sth_machine->execute($mach);
    my ($mid) = $sth_machine->fetchrow_array;
    fatal "no such machine: $mach" if !defined $mid;
    $sth_application->execute($app);
    my ($aid) = $sth_application->fetchrow_array;
    fatal "no such application: $app" if !defined $aid;
    $sth_install->execute($mid, $aid, $qual, $vers);
}

sub on_machine_set {
    my $usage = 'on MACHINE set APPLICATION[:QUALIFIER] [KEY=VALUE...]';
    usage($usage) if @_ < 3;
    my $mach = shift;
    my ($app, $qual) = appqual(shift());
    my @props = argv2props(@_);
    my ($vers) = map { $_->[1] } grep { $_->[0] eq 'version' } @props;
    @props = grep { $_->[0] ne 'version' } @props;
    my @rm = map { defined $_->[1] ? () : ($_->[0]) } @props;
    @props = grep { defined $_->[1] } @props;
    my $iid = find_instance_id($mach, $app, $qual)
        or fatal("no such instance on $mach: " . appqual2str($app, $qual));
    # Set version
    if (defined $vers) {
        my $sql = q{
            UPDATE  instances
            SET     version = ?
            WHERE   id = ?
        };
        my $sth = $dbh->prepare($sql);
        $sth->execute($vers, $iid);
    }
    # Set properties
    if (@props) {
        my $sql = q{
            INSERT OR IGNORE INTO instance_properties
                    (instance, key, value)
        };
        my @params;
        my @values;
        foreach (@props) {
            my ($k, $v) = @$_;
            push @values, q{
                    (?,        ?,   ?    )
            };
            push @params, $iid, $k, $v;
        }
        substr($values[0], 8, 6) = 'VALUES';
        $sql .= join(",\n", @values);
        my $sth = $dbh->prepare($sql);
        $sth->execute(@params);
    }
    # Delete undefined properties
    if (@rm) {
        my $sql = sprintf q{
            DELETE  FROM instance_properties
            WHERE   instance = ?
            AND     key IN ( %s )
        }, join(', ', map { '?' } @rm);
        my $sth = $dbh->prepare($sql);
        $sth->execute(@rm);
    }
}

sub find_instance_id {
    my ($mach, $app, $qual) = @_;
    my $sql = q{
        SELECT  i.id
        FROM    instances i,
                applications a,
                machines m
        WHERE   i.machine = m.id
        AND     i.application = a.id
        AND     lower(m.name) = lower(?)
        AND     lower(a.name) = lower(?)
    };
    my @params = ($mach, $app);
    if (!defined $qual) {
        $sql .= q{
        AND     qualifier IS NULL
        };
    }
    elsif ($qual ne '*') {
        $sql .= q{
        AND     qualifier = ?
        };
        push @params, $qual;
    }
    my $sth = $dbh->prepare($sql);
    $sth->execute(@params);
    my @iids;
    while (my ($iid) = ($sth->fetchrow_array)) {
        push @iids, $iid;
    }
    die "multiple matches: $mach ", appqual2str($app, $qual)
        if @iids > 1;
    return if !@iids;
    return shift @iids;
}

sub on_machine_get {
    usage() if @_ < 2;
    my $mach = shift @_;
    my ($app, $qual) = appqual(shift @_);
    my $iid = find_instance_id($mach, $app, $qual)
        or fatal("no such instance on $mach: " . appqual2str($app, $qual));
    my $sql = q{
        SELECT  key,
                value
        FROM    instance_properties
        WHERE   instance = ?
    };
    my @params = ($iid);
    if (@_) {
        $sql .= sprintf q{
        AND     p.key IN ( %s )
        }, join(', ', map { '?' } @_);
        push @params, @_;
    }
    my $sth = $dbh->prepare($sql);
    $sth->execute(@params);
    while (my ($k, $v) = $sth->fetchrow_array) {
        if (@_ == 1) {
            print $v, "\n";
            last;
        }
        print "$k $v\n";
    }
}

sub instances_on_machine {
    my ($mach) = @_;
    my $sth = $dbh->prepare(q{
        SELECT  a.name,
                i.qualifier,
                i.version
        FROM    instances i,
                applications a,
                machines m
        WHERE   i.application = a.id
        AND     i.machine = m.id
        AND     lower(m.name) = lower(?)
    });
    $sth->execute($mach);
    my @apps;
    while (my $inst = $sth->fetchrow_hashref) {
        push @apps, $inst;
    }
    return @apps;
}

sub application_paths_on_machine {
    my ($mach, $inst, $what) = @_;
    my $sql = q{
        SELECT  p.*
        FROM    instance_paths p,
                instances i,
                applications a,
                machines m
        WHERE   p.app = i.id
        AND     i.application = a.id
        AND     i.machine = m.id
        AND     lower(m.name) = lower(?)
        AND     lower(a.name) = lower(?)
    };
    my @params = ($mach, $inst);
    if (defined $what) {
        $sql .= q{
            AND     lower(p.what) = lower(?)
        };
        push @params, $what;
    }
    my $sth = $dbh->prepare($sql);
    $sth->execute(@params);
    my @paths;
    while (my $path = $sth->fetchrow_hashref) {
        push @paths, $path;
    }
    return @paths;
}

sub application_ports_on_machine {
    my ($mach, $inst, $qual, $addr) = @_;
    my $sql0 = q{
        SELECT  p.port
              , a.name
              , i.qualifier
    };
    my $sql1 = q{
        FROM    instance_ports p
        INNER JOIN instances i ON p.app = i.id
        INNER JOIN applications a ON i.application = a.id
        INNER JOIN machines m ON i.machine = m.id
    };
    my $sql2 = q{
        WHERE   p.app = i.id
        AND     i.application = a.id
        AND     i.machine = m.id
        AND     lower(m.name) = lower(?)
    };
    my @params = ($mach);
    if (defined $inst) {
        $sql2 .= q{
            AND     lower(a.name) = lower(?)
        };
        push @params, $inst;
    }
    if (defined $qual) {
        $sql2 .= q{
            AND     lower(i.qualifier) = lower(?)
        };
        push @params, $qual;
    }
    if (defined $addr) {
        $sql0 .= q{
              , ad.address
        };
        $sql1 .= q{
            OUTER LEFT JOIN addresses ad ON ad.machine = machine.id
        };
        $sql2 .= q{
            AND     lower(ad.address) = lower(?)
        };
        push @params, $addr;
    }
    my $sql = $sql0 . $sql1 . $sql2;
    my $sth = $dbh->prepare($sql);
    $sth->execute(@params);
    my @ports;
    while (my $port = $sth->fetchrow_hashref) {
        push @ports, $port;
    }
    return @ports;
}

sub argv2props {
    my @props;
    my $argv = @_ ? \@_ : \@ARGV;
    while (@$argv) {
        local $_ = shift @$argv;
        die $_ if !m{^([^=]+)(?:=(.*)|!)$};
        push @props, [$1, $2];
    }
    return @props;
}

sub getopts {
    GetOptions(
        'd|database=s' => \$dbfile,
        @_,
    ) or usage;
}

sub initdb {
    my ($dbfile) = @_;
    opendb($dbfile);
    my @sql = split /;\n/, q{
        CREATE TABLE machines (
            id          INTEGER PRIMARY KEY,
            name        VARCHAR UNIQUE NOT NULL,
            osname      VARCHAR,
            osversion   VARCHAR
        );
        CREATE TABLE networks (
            id          INTEGER PRIMARY KEY,
            name        VARCHAR NOT NULL,
            netmask     INTEGER NOT NULL
        );
        CREATE TABLE addresses (
            id          INTEGER PRIMARY KEY,
            ipversion   INTEGER NOT NULL DEFAULT 4,
            address     VARCHAR,
            machine     INTEGER NULL,
            network     INTEGER NULL
        );
        CREATE TABLE hostnames (
            id          INTEGER PRIMARY KEY,
            hostname    VARCHAR NOT NULL,
            address     INTEGER NOT NULL
        );
        CREATE TABLE applications (
            id          INTEGER PRIMARY KEY,
            name        VARCHAR NOT NULL,
            description VARCHAR NULL
        );
        CREATE TABLE instances (
            id          INTEGER PRIMARY KEY,
            machine     INTEGER NOT NULL,
            application INTEGER NOT NULL,
            version     VARCHAR,
            qualifier   VARCHAR NULL);
        CREATE TABLE instance_ports (
            id          INTEGER PRIMARY KEY,
            instance    INTEGER NOT NULL,
            address     INTEGER NULL,
            port        INTEGER NULL,
            description VARCHAR
        );
        CREATE TABLE instance_paths (
            id          INTEGER PRIMARY KEY,
            instance    INTEGER NOT NULL,
            path        VARCHAR NOT NULL,
            what        VARCHAR, /* root|exec|log|... */
            description VARCHAR NULL
        );
        CREATE TABLE instance_properties (
            instance    INTEGER NOT NULL,
            key         VARCHAR,
            value       VARCHAR
        );
    };
    foreach my $sql (@sql) {
        $dbh->do($sql);
    }
}
