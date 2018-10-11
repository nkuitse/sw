package App::sw::Plugin::hello;

use strict;
use warnings;

sub new {
    my $cls = shift;
    bless { @_ }, $cls;
}

sub commands {
    return (
        'hello' => \&hello,
    );
}

sub hooks { }

sub hello {
    @_ = qw(world) if !@_;
    print STDERR "Hello @_\n";
}

1;
