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
    $self->app->orient;
    if (@ARGV == 1) {
        $self->list_howtos(@ARGV);
    }
    elsif (@ARGV == 2) {
        $self->show_howto(@ARGV);
    }
    else {
        $self->set_howto(@ARGV);
    }
}

sub list_howtos {
    my ($self, $path) = @_;
    my $app = $self->app;
    my @paths = $self->paths($path);
    my %howto;
    while (@paths) {
        my $path = shift @paths;
        my @children = $app->children($path.'/howto');
        my @howtos;
        foreach (@children) {
            my $chpath = $_->{'path'};
            (my $chname = $chpath) =~ s{.*/}{};
            push @howtos, $chname;
        }
        $howto{$path} = \@howtos if @howtos;
    }
    @paths = sort keys %howto;
    while (@paths) {
        $path = shift @paths;
        my @howtos = @{ $howto{$path} };
        print $path, "\n";
        print $_, "\n" for @howtos;
        print "\n" if @paths;
    }
}

sub paths {
    my ($self, $path) = @_;
    return ($path) if $path =~ m{^/};
    my $dbh = $self->app->dbh;
    my $sth = $dbh->prepare("SELECT path FROM objects WHERE path LIKE '%/' || ? || '/howto'");
    $sth->execute($path);
    my @paths;
    while (my ($howtopath) = $sth->fetchrow_array) {
        $howtopath =~ s{/howto$}{};
        push @paths, $howtopath;
    }
    fatal("no such object: $path") if !@paths;
    return @paths;
}

sub show_howto {
    my ($self, $task, $path) = @_;
    my $app = $self->app;
    my @paths = $self->paths($path);
    while (@paths) {
        $path = shift @paths;
        my $howtopath = "$path/howto";
        my $taskpath = "$howtopath/$task";
        my $taskobj = eval { $app->object($taskpath, 1) }
            or next;
            # or fatal("no information on how to $task $path");
        my $howtoobj = $app->object($howtopath);
        my @taskprops = $app->get($taskobj);
        my @howtoprops = $app->get($howtoobj);
        my ($cmd) = map { $_->[0] eq 'cmd' ? ($_->[1]) : () } @taskprops, @howtoprops;
        my ($user) = map { $_->[0] eq 'user' ? ($_->[1]) : () } @taskprops, @howtoprops;
        my ($cwd) = map { $_->[0] eq 'cwd' ? ($_->[1]) : () } @taskprops, @howtoprops;
        my @tasknotes = map { $_->[0] eq 'note' ? ($_->[1]) : () } @taskprops;
        my @howtonotes = map { $_->[0] eq 'note' ? ($_->[1]) : () } @howtoprops;
        my @notes = @tasknotes ? @tasknotes : @howtonotes;
        my %env = map {
            $_->[0] eq 'env'
                ? (split /=/, $_->[1], 2)
                : ()
        } @howtoprops, @taskprops;
        my $prompt = '$';
        print $path, "\n";
        if (!defined $user) {
            print "[as the appropriate user]\n";
        }
        elsif ($user eq 'root') {
            print "[as root]\n";
            $prompt = '#';
        }
        else {
            print "[as $user]\n";
        }
        print "$prompt cd $cwd\n" if defined $cwd;
        foreach my $k (sort keys %env) {
            my $v = $env{$k};
            # TODO Expand %(...)
            print $prompt, 'export ', $k, '=', shell_quote($v), ' ';
        }
        # TODO Expand %(...)
        print $prompt, ' ', $cmd, "\n";
        print '*** NOTE: ', $_, "\n" for @notes;
        print "\n" if @paths;
    }
}

sub set_howto {
    my ($self, $task, $path) = splice @_, 0, 3;
    $path =~ m{^/} or fatal("to set how-to information, you must supply a full path");
    $path .= '/howto/' . $task;
    my $app = $self->app;
    my @params = @_;
    if (eval { $app->object($path) }) {
        $app->_transact(sub {
            $app->set($path, @params);
        });
    }
    else {
        $app->_transact(sub {
            $app->insert($path, @params);
        });
    }
}

sub find_objects {
    my ($self, $name) = @_;
    my $app = $self->app;
    my $cpath = $app->bound('config')
        or fatal("unable to resolve $name: \@config is not bound");
    1;
    return find_path_to_machine("$cpath/machine"),
           find_path_to_software("$cpath/software");
}

1;
