#!/usr/bin/perl

package App::sw::Plugin::software;

use strict;
use warnings;

sub new {
    my $cls = shift;
    bless { @_ }, $cls;
}

sub app { shift()->{'app'} }

sub commands {
    return (
        'software' => \&software,
        'instances' => \&instances,
    );
}

sub software {
    my $self = shift;
    my $app = $self->app;
    $app->getopts;
    @ARGV = qw(ls) if !@ARGV;
    my $cmd = shift @ARGV;
    my $sub = $self->can('software_'.$cmd)
        or $app->usage;
    $sub->($self);
}

sub software_root {
    my ($self) = @_;
    my $sroot = $self->root('software')->{'path'};
    print $sroot, "\n";
}

sub software_on {
    my $self = shift;
    my $app = $self->app;
    $app->usage('software on MACHINE') if @ARGV != 1;
    my ($name) = @ARGV;
    my $mroot = $self->root('machines')->{'path'};
    my $sroot = $self->root('software')->{'id'};
    my $machine = eval { $app->object(sprintf '%s/%s', $mroot, $name) }
        or $app->fatal("no such machine: $name");
    my $msroot = $app->property($machine, 'software');
    my @software;
    if ($msroot) {
        @software = grep {
            $_->{'path'} =~ m{^$mroot/}
        } $app->find($msroot, '@instance-of');
    }
    print $_->{'path'}, "\n" for @software;
}

sub root {
    my ($self, $type) = @_;
    my $app = $self->app;
    my ($cpath) = $app->bound('config')
        or $app->fatal("unable to find $type root: \@config is not bound");
    my $obj = eval { $app->object("$cpath/$type") };
    $app->fatal("$type root not configured") if !$obj;
    my $cattr = $app->property($obj->{'path'}, 'root');
    $app->fatal("$type root not configured correctly")
        if !$cattr || !ref $cattr;
    return $cattr;
}

sub instances {
    my $self = shift;
    my $app = $self->app;
    $app->getopts;
    if (@ARGV > 1 && $ARGV[0] eq 'of') {
        shift @ARGV;
        $self->instances_of;
    }
    elsif (@ARGV > 1 && $ARGV[0] eq 'on') {
        shift @ARGV;
        $self->instances_of;
    }
    elsif (@ARGV) {
        $app->usage('instances [of NAME|on MACHINE]');
    }
    else {
        my $dbh = $app->dbh;
        my $sql = q{
            SELECT  o.path
            FROM    objects o,
                    properties p
            WHERE   o.id = p.object
            AND     p.key = 'instance-of'
            AND     p.ref IS NOT NULL
            AND     p.ref IN (
                        SELECT  sp.id
                        FROM    bindings b,
                                objects cp,
                                objects co,
                                properties cop,
                                objects sp
                        WHERE   b.ref = cp.id
                        AND     co.parent = cp.id
                        AND     substr(co.path, length(cp.path)+2) = 'software'
                        AND     co.id = cop.object
                        AND     cop.key = 'root'
                        AND     cop.ref IS NOT NULL
                        AND     cop.ref = sp.parent
                    )
            ORDER   BY o.path
        };
        my $sth = $dbh->prepare($sql);
        $sth->execute;
        while (my ($path) = $sth->fetchrow_array) {
            print $path, "\n";
        }
    }
}

sub instances_of {
    my ($self) = @_;
    my $app = $self->app;
    $app->usage('instances NAME') if !@ARGV;
    my $name = shift @ARGV;
    my $dbh = $app->dbh;
    my $sql = q{
        SELECT  o.path
        FROM    objects o,
                properties p
        WHERE   o.id = p.object
        AND     p.key = 'instance-of'
        AND     p.ref IS NOT NULL
        AND     p.ref IN (
                    SELECT  sp.id
                    FROM    bindings b,
                            objects cp,
                            objects co,
                            properties cop,
                            objects sp
                    WHERE   b.ref = cp.id
                    AND     co.parent = cp.id
                    AND     substr(co.path, length(cp.path)+2) = 'software'
                    AND     co.id = cop.object
                    AND     cop.key = 'root'
                    AND     cop.ref IS NOT NULL
                    AND     cop.ref = sp.parent
                    AND     sp.path LIKE '%/' || ?
                )
        ORDER   BY o.path
    };
    my $sth = $dbh->prepare($sql);
    $sth->execute($name);
    while (my ($path) = $sth->fetchrow_array) {
        print $path, "\n";
    }
}

sub software_install {
    my ($self) = @_;
    my $app = $self->app;
    $app->usage('install NAME on MACHINE');
    my $name = shift @ARGV;
    foreach my $machine (@ARGV) {
        $self->install($name, $machine);
    }
}

1;
