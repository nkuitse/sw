package App::sw::Plugin::getent;

use strict;
use warnings;

*usage = *App::sw::main::usage;

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
    $self->app->getopts(
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
                my $path = "$hpfx/$host";
                my $obj = eval { $app->object($path, 1) };
                if ($obj) {
                    $app->append($obj, $k => $addr)
                        if !grep { $_->[0] eq $k } $app->get($obj);
                }
                else {
                    $obj = $app->insert($path, $k => $addr);
                }
            }
        }
    });
}

sub getent_passwd {
    my $self = shift;
    my $app = $self->app;
    my $upfx = '/user';
    my $file = '/etc/passwd';
    $self->app->getopts(
        'p=s' => \$upfx,
        'f=s' => \$file,
    );
    open my $fh, '<', $file or die "open $file: $!";
    $app->_transact(sub {
        while (<$fh>) {
            chomp;
            my ($login, $pass, $uid, $gid, $gecos, $home, $shell) = split /:/;
            my $path = "$upfx/$login";
            my $obj = eval { $app->object($path, 1) };
            if ($obj) {
                1;  # Already in sw
            }
            else {
                $obj = $app->insert($path,
                    'uid' => $uid,
                    'gid' => $gid,
                    'gecos' => $gecos,
                    'home' => $home,
                    'shell' => $shell,
                );
            }
        }
    });
}

1;
