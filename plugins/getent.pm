package App::sw::Plugin::getent;

use strict;
use warnings;

*usage = *App::sw::main::usage;
*orient = *App::sw::main::orient;

my $usagestr = 'getent hosts | host HOST | users | user USER | ...';

sub new {
    my $cls = shift;
    bless { @_ }, $cls;
}

sub app { shift()->{'app'} }

sub commands {
    return (
        'getent' => \&getent,
    );
}

sub hooks { }

sub getent {
    my $self = shift;
    usage($usagestr) if !@ARGV;
    my $subcmd = shift @ARGV;
    unshift @_, $self;
    goto &{ __PACKAGE__->can('getent_'.$subcmd) || usage($usagestr) };
}

sub getent_hosts {
    my $self = shift;
    my $app = $self->app;
    my $hpfx = '/host';
    my $file = '/etc/hosts';
    $self->app->orient(
        'p=s' => \$hpfx,
        'f=s' => \$file,
    );
    open my $fh, '<', $file or die "open $file: $!";
    $app->_transact(sub {
        while (<$fh>) {
            next if !/^\s*[:0-9]/;
            next if /^127\./ || /\blocalhost6?\b/;
            chomp;
            my ($addr, @hosts) = split /\s+/, $_;
            my $k = $addr =~ /:/ ? 'ip6addr' : 'ip4addr';
            foreach my $host (@hosts) {
                my $obj = eval { $app->object("$hpfx/$host") }
                          ||     $app->insert("$hpfx/$host");
                $app->append("$hpfx/$host",
                    $k => $addr,
                );
            }
        }
    });
}

1;
