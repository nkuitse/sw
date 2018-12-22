package App::sw::Plugin::objects;

use strict;
use warnings;

*usage = *App::sw::main::usage;
*fatal = *App::sw::main::fatal;

sub new {
    my $cls = shift;
    bless { @_ }, $cls;
}

sub app { shift()->{'app'} }

sub commands {
    return (
        'users' => \&users,         'user' => \&user,
        'groups' => \&groups,       'group' => \&group,
        'machines' => \&machines,   'machine' => \&machine,
        'hosts' => \&hosts,         'host' => \&host,
        'resources' => \&resources, 'resource' => \&resource,
    );
}

sub hooks { }

sub machines {
    shift()->_list_objects('machines');
}

sub hosts {
    shift()->_list_objects('hosts');
}

sub users {
    shift()->_list_objects('users');
}

sub groups {
    shift()->_list_objects('groups');
}

sub resources {
    shift()->_list_objects('resources');
}

sub _list_objects {
    my ($self, $what) = @_;
    my $app = $self->app;
    my ($long);
    $app->orient(
        'l|long' => \$long,
    );
    usage("$what [-l]") if @ARGV;
    my @objects = $self->all($what);
    if ($long) {
        print $_, "\n" for sort map { $_->{'path'} } @objects;
    }
    else {
        print $_, "\n" for sort map { basename($_->{'path'}) } @objects;
    }
}

sub user {
    my $self = shift;
    my $app = $self->app;
    my ($long, $passwd);
    $app->orient(
        'l|long' => \$long,
        'p|passwd' => \$passwd,
    );
    usage('user [-l] USERNAME') if @ARGV != 1;
    my ($name) = @ARGV;
    my @users = $self->find('users', $name)
        or fatal("no such user: $name");
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
    my ($uid, $gid, $home) = map {
        my $values = $props->{$_};
        fatal("no $_ for $user")
            if !$values || !@$values;
        fatal("multiple $_ for $user")
            if @$values > 1;
        $values->[0];
    } qw(uid gid home);
    my ($gecos, $shell) = map {
        my $values = $props->{$_};
        $values && @$values == 1 ? ($values->[0]) : ('')
    } qw(gecos shell);
    return join(':', $username, 'x', $uid, $gid, $gecos, $home, $shell);
}

sub all {
    my ($self, $what, $name) = @_;
    my $app = $self->app;
    my @roots = map { $_->[0] eq '@root' ? ($_->[1]{'path'}) : () }
                map { $app->get("$_/$what") }
                $app->bound('config');
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
