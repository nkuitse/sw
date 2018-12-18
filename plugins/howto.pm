package App::sw::Plugin::howto;

use strict;
use warnings;

use String::ShellQuote qw(shell_quote);

*usage = *App::sw::main::usage;
*fatal = *App::sw::main::fatal;

my $usagestr = 'howto NODE TASK [...]';

sub new {
    my $cls = shift;
    bless { @_ }, $cls;
}

sub app { shift()->{'app'} }

sub commands {
    return (
        'howto' => \&howto,
    );
}

sub hooks { }

sub howto {
    my $self = shift;
    usage($usagestr) if @ARGV < 2;
    my ($task, $path) = splice @ARGV, 0, 2;
    my $app = $self->app;
    $app->orient;
    my $taskpath = "$path/howto/$task";
    my $taskobj = eval { $app->object($taskpath, 1) };
    if (!@ARGV) {
        fatal("no information on how to $task $path") if !$taskobj;
        my @props = $app->get($taskobj);
        my ($cmd) = map { $_->[0] eq 'cmd' ? ($_->[1]) : () } @props;
        my ($user) = map { $_->[0] eq 'user' ? ($_->[1]) : () } @props;
        my ($cwd) = map { $_->[0] eq 'cwd' ? ($_->[1]) : () } @props;
        my @env = map { $_->[0] eq 'env' ? ($_->[1]) : () } @props;
        my $prompt = '$';
        if (!defined $user) {
            print "[as the appropriate user]\n";
        }
        elsif ($user eq 'root') {
            print "[as root]\n";
            $prompt = '#';
        }
        print "$prompt cd $cwd\n" if defined $cwd;
        foreach (@env) {
            my ($k, $v) = split /=/, $_, 2;
            # TODO Expand %(...)
            print $prompt, 'export ', $k, '=', shell_quote($v), ' ';
        }
        # TODO Expand %(...)
        print $prompt, ' ', $cmd, "\n";
    }
    ### elsif ($taskobj) {
    ###     $app->append($taskobj, ...);
    ### }
    ### else {
    ###     $taskobj = $app->insert($path, ...);
    ### }
}

1;
