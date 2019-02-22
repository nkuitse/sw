package App::sw::Plugin::objects;

use strict;
use warnings;

sub new {
    my $cls = shift;
    bless { @_ }, $cls;
}

sub app { shift()->{'app'} }

sub commands {
    return (
        'users' => \&users, 'user' => \&user,
        'groups' => \&groups, 'group' => \&group,
        'machines' => \&machines, 'machine' => \&machine,
        'hosts' => \&hosts, 'host' => \&host,
        'networks' => \&networks, 'network' => \&network,
        'resources' => \&resources, 'resource' => \&resource,
        'organizations' => \&organizations, 'organization' => \&organization,
    );
}

sub hooks { }

sub users {
    shift()->_list_objects('users');
}

sub groups {
    shift()->_list_objects('groups');
}

sub machines {
    shift()->_list_objects('machines');
}

sub hosts {
    my ($self) = @_;
    my $app = $self->app;
    my ($dotless);
    $app->getopts(
        's|dotless' => \$dotless,
    );
    my @filter;
    if ($dotless) {
        @filter = (sub {
            basename($_->{'path'}) !~ /\./;
        });
    }
    shift()->_list_objects('hosts', @filter);
}

sub networks {
    shift()->_list_objects('networks');
}

sub resources {
    shift()->_list_objects('resources');
}

sub organizations {
    shift()->_list_objects('organizations');
}

sub machine {
    my $self = shift;
    my $app = $self->app;
    my ($long);
    $app->getopts(
        'l|long' => \$long,
    );
    $app->usage('machine [-l] NAME') if @ARGV != 1;
    my ($name) = @ARGV;
    my @machines = $self->find('machines', $name)
        or $app->fatal("no such machine: $name");
    print $_, "\n" for sort map { $_->{'path'} } @machines;
}

sub _list_objects {
    my ($self, $what, $filter) = @_;
    my $app = $self->app;
    my ($long, $roots);
    $app->getopts(
        'l|long' => \$long,
        'r|roots' => \$roots,
    );
    $app->usage("$what [-lr]") if @ARGV;
    if ($roots) {
        my @roots = $self->roots($what);
        print $_, "\n" for sort @roots;
    }
    else {
        my @objects = $self->all($what);
        @objects = grep { $filter->() } @objects if $filter;
        if ($long) {
            print $_, "\n" for sort map { $_->{'path'} } @objects;
        }
        else {
            print $_, "\n" for sort map { basename($_->{'path'}) } @objects;
        }
    }
}

sub user {
    my $self = shift;
    my $app = $self->app;
    my ($long, $passwd);
    $app->getopts(
        'l|long' => \$long,
        'p|passwd' => \$passwd,
    );
    $app->usage('user [-l] USERNAME') if @ARGV != 1;
    my ($name) = @ARGV;
    my @users = $self->find('users', $name)
        or $app->fatal("no such user: $name");
    if ($passwd) {
        print $self->user2passwd($_), "\n" for @users;
    }
    else {
        print $_, "\n" for sort map { $_->{'path'} } @users;
    }
}

# --- Other functions

sub user2passwd {
    my ($self, $user) = @_;
    my $props = $self->app->properties($user);
    my $username = basename($user->{'path'});
    my $app = $self->app;
    my ($uid, $gid, $home) = map {
        my $values = $props->{$_};
        $app->fatal("no $_ for $user")
            if !$values || !@$values;
        $app->fatal("multiple $_ for $user")
            if @$values > 1;
        $values->[0];
    } qw(uid gid home);
    my ($gecos, $shell) = map {
        my $values = $props->{$_};
        $values && @$values == 1 ? ($values->[0]) : ('')
    } qw(gecos shell);
    return join(':', $username, 'x', $uid, $gid, $gecos, $home, $shell);
}

sub roots {
    my ($self, $what) = @_;
    my $app = $self->app;
    return map { $_->[0] eq '@root' ? ($_->[1]{'path'}) : () }
           map { $app->get("$_/$what") }
           $app->bound('config');
}

sub all {
    my ($self, $what, $name) = @_;
    my $app = $self->app;
    my @roots = $self->roots($what);
    return map { $app->children($_) } @roots;
}

sub find {
    my ($self, $what, $name) = @_;
    my $app = $self->app;
    my @roots = map { $_->[0] eq '@root' ? ($_->[1]{'path'}) : () }
                map { $app->get("$_/$what") }
                $app->bound('config');
    return map { eval { $app->object("$_/$name") } } @roots;
}

sub basename {
    local $_ = shift;
    s{.*/}{};
    return $_;
}

1;
