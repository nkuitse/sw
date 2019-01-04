package App::sw::Plugin::mon;

use strict;
use warnings;

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

sub initdb {
    my ($self, $dbfile) = @_;
    my $app = $self->app;
    my $dbh = $app->dbh;
    my @sql = split /;\n/, q{
        CREATE TABLE mon.statuses (
            id      INTEGER PRIMARY KEY,
            code    VARCHAR NOT NULL,
            name    VARCHAR
        );
        INSERT INTO mon.statuses
            (id, code, name)
        VALUES
            (0, 'OK',    'OK'),
            (1, 'WARN',  'Warning'),
            (2, 'ERR',   'Error'),
            (3, 'MAINT', 'Maintenance');
        CREATE INDEX mon.statuses_id   ON statuses (id);
        CREATE INDEX mon.statuses_code ON statuses (code);
        CREATE TABLE mon.states (
            target  INTEGER NOT NULL /* REFERENCES main.objects(id) */,
            status  INTEGER NOT NULL REFERENCES statuses(id),
            first   INTEGER NOT NULL,
            last    INTEGER NOT NULL,
            iscur   INTEGER NOT NULL DEFAULT 1
        );
        CREATE INDEX mon.states_target       ON states(target);
        CREATE INDEX mon.states_target_first ON states(target, first);
        CREATE INDEX mon.states_target_last  ON states(target, last);
        CREATE INDEX mon.states_target_iscur ON states(target, iscur);
    };
    foreach (@sql) {
        print STDERR $_, "\n...";
        $dbh->do($_);
        print STDERR "OK\n";
    }
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

sub mon_status {
    my $self = shift;
    my $app = $self->app;
    my ($long);
    $app->getopts(
        'l|long' => \$long,
    );
    $app->usage('status [-l] TARGET') if @ARGV != 1;
    my ($path) = @ARGV;
    my $dbh = $app->dbh;
    my $sth = $dbh->prepare(q{
        SELECT  s.code,
                s.name,
                m.first,
                m.last
        FROM    mon.states   m,
                mon.statuses s,
                main.objects o
        WHERE   m.status = s.id
        AND     m.target = o.id
        AND     o.path = ?
        AND     m.iscur = 1
    });
    $sth->execute($path);
    if (my @row = $sth->fetchrow_array) {
        my ($code, $name, $first, $last) = @row;
        1;
    }
}

sub mon_check {
    my $self = shift;
    my $app = $self->app;
    $app->getopts;
    $app->_transact(sub {
        1;
    });
}

1;
