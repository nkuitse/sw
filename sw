#!/usr/bin/perl

package App::sw::main;

use strict;
use warnings;

use FindBin qw($Bin $Script);
use Getopt::Long
    qw(:config posix_default gnu_compat require_order bundling no_ignore_case);

use constant PROG => 'sw';
use constant PREFIX => '/usr/local';
use constant DB_DIR => '/var/local/sw';
use constant PLUGIN_DIR => '/usr/local/sw/plugins';
use constant ENV_VAR => 'SW_DIR';

use constant IS_MAGIC  => 256;

use constant OP_SET    => 1;
use constant OP_APPEND => 2;
use constant OP_REMOVE => 4;
use constant OP_KEY    => 8;
use constant OP_ANY    => ~IS_MAGIC;

sub usage;
sub fatal;

(my $prog = $0) =~ s{.+/}{};

my $root = PREFIX . '/' . PROG;
my $dir = $ENV{ENV_VAR()} || DB_DIR;
my $dbfile = 'catalog.sq3';
my (%command, %hook);
my $app = App::sw->new('file' => "$dir/$dbfile");

init_commands();
App::sw->init_plugins(PLUGIN_DIR);

my ($cmd, $running);
@ARGV = qw(shell) if !@ARGV;
$cmd = shift @ARGV;
$cmd =~ tr/-/_/;
&{ $command{$cmd} || __PACKAGE__->can('cmd_'.$cmd) || usage };

# --- Command handlers

sub cmd_help {
    print STDERR "Help!\n";
}

sub cmd_init {
    #@ init [DIR] :: initialize a new database
    usage if @ARGV > 1;
    @ARGV = qw(.) if !@ARGV;
    ($dir) = @ARGV;
    fatal "database file $dir/$dbfile already exists"
        if -e "$dir/$dbfile";
    -d $dir or mkdir $dir or fatal "mkdir $dir: $!";
    chdir $dir or fatal "chdir $dir: $!";
    $app->create($dbfile);
    print STDERR "initialized: $dir\n";
}

sub cmd_dbi {
    #@ dbi :: open database using sqlite3
    orient();
    usage if @ARGV;
    undef $app;
    exec('sqlite3', $dbfile);
}

### sub cmd_dbq {
###     orient();
###     usage if !@ARGV;
###     my $sql = shift @ARGV;
###     my $sth = sth($sql);
###     $sth->execute(@ARGV);
###     while (my @row = map { defined $_ ? $_ : '' } $sth->fetchrow_array) {
###         print join("\t", @row), "\n";
###     }
###     $sth->finish;
### }
### 
### sub cmd_query {
###     goto &cmd_dbq;
### }

sub cmd_add {
    #@ add PATH [KEY=VAL]...
    #@ add '[' PATH... ']' [KEY=VAL]...
    #= add a node
    orient();
    $app->_transact(sub {
        foreach my $path (argv_pathlist()) {
            $app->insert($path, @ARGV);
        }
    });
}

sub cmd_set {
    #@ set PATH KEY=VAL...
    #@ set '[' PATH... ']' KEY=VAL...
    #= set node properties
    orient();
    my @paths = argv_pathlist();
    usage() if !@ARGV;
    $app->_transact(sub {
        foreach my $path (@paths) {
            $app->set($path, @ARGV);
        }
    });
}

sub cmd_append {
    #@ append PATH KEY=VAL...
    orient();
    my $path = argv_path();
    $app->append($path, @ARGV);
    #my @props = argv_props(OP_SET);
    #$app->append($path, @props);
}

sub cmd_rm {
    #@ rm [-r] PATH...
    my $recurse;
    orient(
        'r|recurse' => \$recurse,
    );
    usage if @ARGV == 0;
    if ($recurse) {
        my (%seen, @rm);
        $app->walk(sub {
            my ($obj, $level, @children) = @_;
            unshift @rm, $obj if !$seen{$obj->{'id'}}++;
        }, @ARGV);
        $app->remove(@rm);
        1;
    }
    else {
        $app->remove($app->object($_)) for @ARGV;
    }
}

sub cmd_mv {
    #@ mv PATH... NEWPARENT/
    orient();
    usage if @ARGV < 2;
    my $dest = pop @ARGV;
    if ($dest =~ m{/$}) {
        # Move under $dest
        (my $destpath = $dest) =~ s{(?<=.)/$}{};
        $app->_transact(sub {
            my $parent = $app->object($destpath);
            foreach my $path (@ARGV) {
                fatal "root node cannot be moved" if $path eq '/';
                fatal "node cannot be moved under its own descendant"
                    if index($dest, $path.'/') == 0;
                my $obj = $app->object($path);
                (my $name = $path) =~ s{.*/}{};
                fatal "object $dest$name already exists"
                    if $app->is_present($dest.$name);
                $app->move($obj, $parent, $name);
            }
        });
    }
    else {
        # Move to dest, i.e., under dest's parent but with dest's name
        usage if @ARGV != 1;
        (my $under = $dest) =~ s{[^/]+$}{};
        (my $name = $dest) =~ s{.*/}{};
        $app->_transact(sub {
            my $parent = $app->object($under);
            my ($path) = @ARGV;
            fatal "root node cannot be moved" if $path eq '/';
            fatal "node cannot be moved under its own descendant"
                if index($dest, $path.'/') == 0;
            my $obj = $app->object($path);
            fatal "object $dest/$name already exists"
                if $app->is_present("$dest/$name");
            $app->move($obj, $parent, $name);
        });
    }
}

sub cmd_ls {
    #@ ls [-lf] [PATH...]
    my ($long, $full);
    orient(
        'l|long' => \$long,
        'f|full-path' => \$full,
    );
    @ARGV = qw(/) if !@ARGV;
    foreach my $path (@ARGV) {
        my $obj = $app->object($path);
        my @objects = $app->children($obj);
        foreach my $obj (@objects) {
            my $name = $obj->{'path'};
            $name =~ s{.+/}{} if !$full;
            if ($long) {
                printf "%6d %s\n", $obj->{'id'}, $name;
            }
            else {
                print $name, "\n";
            }
        }
    }
}

sub cmd_tree {
    #@ tree [PATH...]
    orient();
    usage if @ARGV > 1;
    @ARGV = qw(/) if !@ARGV;
    $app->walk(sub {
        my ($obj, $level, @children) = @_;
        my ($id, $path) = @$obj{qw(id path)};
        (my $name = $path) =~ s{.*/(?=.)}{};
        print '  ' x $level, $name;
        print '/' if @children && $path ne '/';
        print "\n";
    }, @ARGV);
}

sub cmd_get {
    #@ get [-hpk] [PATH...]
    my %opt = ( 'header' => 0, 'path' => 0, 'keys' => 0 );
    orient(
        'h|header' => \$opt{'header'},
        'p|path' => \$opt{'path'},
        'k|keys' => \$opt{'keys'},
    );
    my $path = argv_path();
    my $obj = $app->object($path);
    my @props = $app->get($obj);
    if (@ARGV) {
        my %want = map { $_ => 1 } @ARGV;
        @props = grep { $want{$_->[0]} } @props;
        $opt{'sort'} = [ @ARGV ];
    }
    else {
        $opt{'keys'} = 1;
    }
    _dump_object($obj, \%opt, @props);
}

sub cmd_export {
    #@ export [PATH...]
    # TODO: sort by id to ensure ref integrity when importing!!
    orient();
    @ARGV = qw(/) if !@ARGV;
    my $n = 0;
    $app->walk(sub {
        my ($obj, $level, @children) = @_;
        print "\n" if $n++;
        _dump_object($obj, { 'header' => 1, 'keys' => 1 }, $app->get($obj));
    }, @ARGV);
###     foreach my $k (sort keys %$obj) {
###         my $v = $obj->{$k} // next;
###         printf "#%s=%s\n", $k, $v if $k ne 'path';
###     }
###     my @props = $app->get($obj);
###     foreach (@props) {
###         my ($k, $v) = @$_;
###         printf "%s=%s\n", $k, $v;
###     }
###     print "\n";
### }, @ARGV);
}

sub _dump_object {
    my ($obj, $opt, @props) = @_;
    if ($opt->{'header'}) {
        my $path = $obj->{'path'};
        print $path, "\n";
        foreach my $k (sort keys %$obj) {
            my $v = $obj->{$k} // next;
            printf "#%s=%s\n", $k, $v if $k ne 'path';
        }
    }
    elsif ($opt->{'path'}) {
        my $path = $obj->{'path'};
        print $path, "\n";
    }
    if ($opt->{'sort'} and my @sort = @{ $opt->{'sort'} }) {
        my $i = 0;
        my %order = map { $_ => $i++ } @sort;
        @props = sort { $order{$a->[0]} <=> $order{$b->[0]} } @props;
    }
    foreach (@props) {
        my ($k, $v) = @$_;
        if (ref $v) {
            ($k, $v) = ($k, $v->{'path'});
        }
        if ($opt->{'keys'}) {
            printf "%s=%s\n", $k, $v;
        }
        else {
            print $v, "\n";
        }
    }
}

sub cmd_bind {
    #@ bind NAME PATH
    #= bind a name to a node
    orient();
    usage if @ARGV != 2;
    my $name = shift @ARGV;
    my $path = argv_path();
    usage if $name !~ /^[@]?([A-Za-z]\w*)$/;
    $app->bind($1, $app->object($path));
}

sub cmd_bound {
    #@ bound NAME
    #= print path of the node to which NAME is bound
    #@ bound NAME PATH
    #= check if NAME is bound to PATH
    orient();
    if (@ARGV == 1) {
        my ($what) = @ARGV;
        my @whats = $what =~ m{^/} ? $app->bound(undef, $what) : $app->bound($what, undef);
        print $_, "\n" for @whats;
    }
    elsif (@ARGV == 2) {
        my ($name, $path) = @ARGV;
        if (!$app->bound($name, $path)) {
            exit 3;
        }
    }
    else {
        usage;
    }
}

sub cmd_import {
    #@ import [-i INTERVAL]
    #= import nodes
    my $commit_interval = 100;
    orient(
        'i|commit-every=i' => \$commit_interval,
    );
    local $/ = '';
    my $n = 0;
    eval {
        $app->begin;
        while (<>) {
            # Format:
            #   /path/to/object
            #   key=val
            #   ...
            #   (blank line)
            $n++;
            local @ARGV = grep { !/^#/ } split /\n/;
            my $path = argv_path();
            my $obj = $app->insert_or_update($path, @ARGV);
            print $obj->{'id'}, ' ', $path, "\n";
            if (($n % $commit_interval) == 0) {
                $app->end;
                $app->begin;
            }
        }
        $app->end;
        exit 0;
    };
    $app->rollback;
    fatal "commit failed";
}

sub cmd_find {
    #@ find [-1] [PATH] [KEY=VAL...]
    #@ find [-1] '[' PATH... ']' [KEY=VAL...]
    my $single;
    orient(
        '1' => \$single,
    );
    my @start = argv_pathlist(1);
    @start = qw(/) if !@start;
    if (@ARGV) {
        foreach my $start (@start) {
            my @objects = $app->find($start, @ARGV);
            foreach my $obj (@objects) {
                print $obj->{'path'}, "\n";
                return if $single;
            }
        }
    }
    elsif ($single) {
        usage();
    }
    else {
        foreach my $path (@start) {
            print $path, "\n";
            print $_->{'path'}, "\n" for $app->descendants($path);
        }
    }
}


# --- Other functions

sub orient {
    return if $running;
    GetOptions(
        'd|directory=s' => \$dir,
        @_,
    ) or usage;
    chdir $dir or fatal "chdir $dir: $!";
    if (-e $dbfile) {
        $app->open($dbfile);
    }
    $running = 1;
}

sub subcmd {
    usage if !@ARGV;
    my $subcmd = shift @ARGV;
    my @caller = caller 1;
    $caller[3] =~ /(cmd_\w+)$/ or die;
    goto &{ __PACKAGE__->can($1.'_'.$subcmd) || usage };
}

sub parse_prop {
    local $_ = shift;
    /^([^-+=~!]+)([-+!]?[=~])(.*)$/
        or return [ OP_KEY, $_ ];
    my ($k, $op, $v) = ($1, $2, $3);
    return [ OP_SET,    $k, $v ] if $op eq '=';
    return [ OP_APPEND, $k, $v ] if $op eq '+=';
    return [ OP_REMOVE, $k, $v ] if $op eq '-=';
    fatal "invalid operator $op in key-value pair: $_";
}

sub argv_props {
    my $modes = @_ ? shift() : ~0;
    my @props = map { parse_prop($_) } @ARGV;
    usage if grep { !($modes & $_->[0]) } @props;
    return @props;
}

sub argv_path {
    my ($empty_ok) = 1;
    if (!@ARGV || $ARGV[0] !~ m{^/}) {
        return if $empty_ok;
        usage;
    }
    path(shift @ARGV);
}

sub argv_pathlist {
    my ($empty_ok) = @_;
    my @list;
    if (!@ARGV) {
        return if $empty_ok;
        usage;
    }
    return argv_path($empty_ok) if $ARGV[0] ne '[';
    shift @ARGV;
    usage if !$empty_ok && !grep { $_ eq ']' } @ARGV;
    while (@ARGV) {
        my $arg = shift @ARGV;
        last if $arg eq ']';
        push @list, path($arg);
    }
    return @list;
}

sub path {
    my ($path) = @_;
    $path =~ m{^/$|^(/\w[-.\w+]*)+$} or fatal "invalid object path: $path";
    return $path;
}

sub prop_array {
    return @_ if @_ > 1;
    my ($prop) = @_;
    my @list;
    my %seen;
    while (my ($k, $v) = each %$prop) {
        next if !defined $v;
        foreach (ref $v ? @$v : $v) {
            $seen{$k}{$_} = 1;
        }
    }
    while (my ($k, $v) = each %seen) {
        push @list, map { [$k, $_] } keys %$v;
    }
    return @list;
}

sub init_commands {
    my $h = eval('\%'.__PACKAGE__.'::');
    while (my ($k, $v) = each %$h) {
        next if $k !~ s/^cmd_//;
        $command{$k} = $v;
    }
}

sub current_command {
}

sub fatal {
    print STDERR PROG, ": @_\n";
    exit 2;
}

sub usage {
    my $pfx = 'usage: ';
    if (@_) {
        print STDERR $pfx, PROG, ' ', @_, "\n";
        exit 1;
    }
    my ($found, $printed);
    if (open my $fh, '<', "$Bin/$Script") {
        while (<$fh>) {
            if (!$found) {
                next if !/^sub cmd_(\S+)/ || $1 ne $cmd;
                $found = 1;
            }
            last if /^\}/;
            next if !s/^\s*#\@\s*//;
            chomp;
            s/\s+::.+//;
            print STDERR $pfx, PROG, ' ', $_, "\n";
            $printed = 1;
            $pfx =~ tr/ / /c;
        }
    }
    print STDERR $pfx, PROG, " COMMAND [ARG...]\n" if !$printed;
    exit 1;
}

package App::sw;

use strict;
use warnings;

use DBI;

use constant IS_REF    => 256;

use constant OP_SET    => 1;
use constant OP_APPEND => 2;
use constant OP_REMOVE => 4;
use constant OP_KEY    => 8;
use constant OP_ANY    => ~IS_REF;

my %op2int;

sub new {
    my $cls = shift;
    unshift @_, 'file' if @_ % 2;
    my %self = @_;
    die "db file not specified" if !defined $self{'file'};
    %op2int = (
        '='  => OP_SET,
        '+'  => OP_APPEND,
        '+=' => OP_APPEND,
        '-'  => OP_REMOVE,
        '-=' => OP_REMOVE,
        map { $_ => $_ } (
            OP_SET,
            OP_APPEND,
            OP_REMOVE,
        ),
    ) if !keys %op2int;
    bless \%self, $cls;
}

sub create {
    my $proto = shift;
    my $self = ref $proto ? $proto : $proto->new(@_);
    my $file = $self->{'file'};
    die "db file $file already exists" if -e $file;
    return $self->connect($file)->initialize;
}

sub open {
    my $proto = shift;
    my $self = ref $proto ? $proto : $proto->new(@_);
    my $file = $self->{'file'};
    die "db file $file doesn't exist" if ! -e $file;
    return $self->connect($file);
}

sub connect {
    my ($self, $file) = @_;
    my $dbh = $self->{'dbh'} = (DBI->connect("dbi:SQLite:dbname=$file",'','') or die "connect failed");
    $dbh->{'RaiseError'} = 1;
    $dbh->do('pragma foreign_keys=on');
    return $self;
}

sub initialize {
    my ($self) = @_;
    $self->_transact(sub {
        my ($dbh) = @_;
        $dbh->do($_) for _init_sql_statements();
    });
    return $self;
}

sub is_present {
    my ($self, $obj) = @_;
    return db_object($self->{'dbh'}, $obj, 1);
}


sub object {
    my ($self, $obj) = @_;
    return db_object($self->{'dbh'}, $obj);
}

sub insert {
    my ($self, $path) = splice @_, 0, 2;
    my @props = _props(OP_SET, @_);
    my $obj;
    $self->_transact(sub {
        my ($dbh) = @_;
        $obj = db_create_object($dbh, $path, @props);
    });
    return $obj;
}

sub insert_or_update {
    my ($self, $path) = splice @_, 0, 2;
    my $obj = eval {
        $self->object($path);
    };
    if ($obj) {
        $self->set($obj, @_);
    }
    else {
        $obj = $self->insert($path, @_);
    }
    return $obj;
}

sub remove {
    my ($self, @objects) = @_;
    $self->_transact(sub {
        my ($dbh) = @_;
        db_remove_object($dbh, $_) for @objects;
    });
}

sub move {
    my ($self, $obj, $parent, $name) = @_;
    $self->_transact(sub {
        my ($dbh) = @_;
        db_move_object($dbh, $obj, $parent, $name);
    });
}

sub bind {
    my ($self, $name, $obj) = @_;
    $self->_transact(sub {
        my ($dbh) = @_;
        db_bind($dbh, $name, $obj);
    });
}

sub bound {
    my ($self, $name, $obj) = @_;
    my $dbh = $self->{'dbh'};
    if (!defined $name) {
        return db_bindings_to($dbh, $self->object($obj));
    }
    elsif (!defined $obj) {
        return db_bindings_from($dbh, $name);
    }
    else {
        return db_binding($dbh, $name, $obj);
    }
}
        
sub unbind {
    my ($self, $name, $obj) = @_;
    $self->_transact(sub {
        my ($dbh) = @_;
        db_unbind($dbh, $name);
    });
}

sub get {
    my $self = shift;
    my $o = shift;
    my $dbh = $self->{'dbh'};
    my %want = map { $_ => 1 } @_;
    my @props = grep { !%want || $want{$_->[1]} } db_get_properties($self->{'dbh'}, $o);
    return map {
        my ($op, $k, $v) = @$_;
        $op & IS_REF
            ? [ '@'.$k, db_object($dbh, $v) ]
            : [ $k, $v                  ]
    } @props;
}

sub set {
    my $self = shift;
    my $o = shift;
    my @props = _props(OP_SET|OP_APPEND|OP_REMOVE, @_);
    $self->_transact(sub {
        my ($dbh) = @_;
        db_set_properties($dbh, $o, @props);
    });
}

sub append {
    my $self = shift;
    my $o = shift;
    my @props = _props(OP_SET, @_);
    $self->_transact(sub {
        my ($dbh) = @_;
        db_insert_properties($dbh, $o, @props);
    });
}

sub children {
    my ($self, $obj) = @_;
    my $dbh = $self->{'dbh'};
    my @children = db_get_children($dbh, $obj);
    return @children;
}

sub descendants {
    my ($self, $obj) = @_;
    my $dbh = $self->{'dbh'};
    my @children = db_get_descendants($dbh, $obj);
    return @children;
}

sub find {
    my ($self, $o) = splice @_, 0, 2;
    my $dbh = $self->{'dbh'};
    return db_find_objects($dbh, $o, _props(OP_SET|OP_KEY, @_));
}

sub walk {
    my ($self, $proc, @roots) = @_;
    @roots = ('/') if !@roots;
    my $walker;
    my $level = 0;
    my $dbh = $self->{'dbh'};
    $walker = sub {
        my ($obj) = @_;
        my @children = db_get_children($dbh, $obj);
        $proc->($obj, $level, @children);
        $level++;
        $walker->($_) for @children;
        $level--;
    };
    $walker->($self->object($_)) for @roots;
}

sub begin {
    my ($self) = @_;
    my $dbh = $self->{'dbh'};
    $dbh->begin_work if !$self->{'txlevel'}++;
}

sub end {
    my ($self) = @_;
    my $dbh = $self->{'dbh'};
    $dbh->commit if !--$self->{'txlevel'};
}

sub cancel {
    my ($self) = @_;
    my $dbh = $self->{'dbh'};
    $dbh->rollback;
    --$self->{'txlevel'};
}

# --- Private methods

sub _transact {
    my ($self, $sub) = @_;
    my $dbh = $self->{'dbh'};
    my $ok;
    eval {
        $dbh->begin_work if !$self->{'txlevel'}++;
        $sub->($dbh);
        $dbh->commit if !--$self->{'txlevel'};
        $ok = 1;
    };
    return $self if $ok;
    my $errstr = $dbh->errstr;
    $dbh->rollback;
    die;
}

# --- Database operations

sub db_create_object {
    my ($dbh, $path, @props) = @_;
    my @anc = _ancestor_paths($path);
    shift @anc;
    my $poid = 1;  # root
    while (@anc) {
        my $p = eval { db_object($dbh, $anc[0]) } or last;
        shift @anc;
        $poid = $p->{'id'};
    }
    my $sql = 'INSERT INTO objects (path, parent) VALUES (?, ?)';
    my $sth = $dbh->prepare($sql);
    foreach my $apath (@anc) {
        $sth->execute($apath, $poid);
        $poid = $dbh->sqlite_last_insert_rowid;
    }
    $sth->execute($path, $poid);
    my $obj = {
        'path' => $path,
        'id' => $dbh->sqlite_last_insert_rowid,
    };
    $sth->finish;
    (my $name = $path) =~ s{.+/}{};  # Leave / as /
    push @props, [ OP_SET, ':name', $name ];
    db_insert_properties($dbh, $obj, @props);
    return $obj;
}

sub db_remove_object {
    my ($dbh, $o) = @_;
    my $oid = db_oid($dbh, $o);
    my @children = db_get_children($dbh, $o);
    die "object $oid has children" if @children;
    $dbh->do('DELETE FROM properties WHERE object = ? OR ref = ?', {}, $oid, $oid);
    $dbh->do('DELETE FROM bindings WHERE ref = ?', {}, $oid);
    $dbh->do('DELETE FROM objects WHERE id = ?', {}, $oid);
}

sub db_move_object {
    my ($dbh, $o, $parent, $name) = @_;
    my $obj = db_object($dbh, $o);
    my $oid = db_oid($dbh, $obj);
    my $poid = db_oid($dbh, $parent);
    my $pfx = db_path($dbh, $parent) . '/';
    $pfx =~ s{//+$}{/};
    my $oldpath = db_path($dbh, $obj);
    my $newpath = $pfx . $name;
    my $newpfx = $newpath . '/';
    my $sth;
    $sth = $dbh->prepare('UPDATE objects SET path = ?, parent = ? WHERE id = ?');
    $sth->execute($newpath, $poid, $oid);
    $sth = $dbh->prepare('UPDATE objects SET path = ? || substr(path, ?) WHERE path LIKE ?');
    $sth->execute($newpfx, length($oldpath)+2, $oldpath . '/%');
}

sub db_set_properties {
    my ($dbh, $o, @props) = @_;
    my @del = grep { $_->[0] & (OP_SET|OP_REMOVE) } @props;
    my @add = grep { $_->[0] & (OP_SET|OP_APPEND) } @props;
    $o = db_object($dbh, $o) if ref($o) eq '' && $o !~ /^[0-9]+$/;
    db_remove_properties($dbh, $o, @del) if @del;
    db_insert_properties($dbh, $o, @add) if @add;
}

sub db_insert_properties {
    my ($dbh, $o, @props) = @_;
    return if !@props;
    my $oid = db_oid($dbh, $o);
    my @refs = grep {   $_->[0] & IS_REF  } @props;
    my @vals = grep { !($_->[0] & IS_REF) } @props;
    if (@refs) {
        my $sth = $dbh->prepare(
            sprintf 'INSERT INTO properties (object, key, ref) VALUES %s',
                join(', ', map { sprintf '(?, ?, ?)' } @refs)
        );
        $sth->execute(map { $oid, $_->[1], db_object($dbh, $_->[2])->{'id'} } @refs);
        $sth->finish;
    }
    if (@vals) {
        my $sth = $dbh->prepare(
            sprintf 'INSERT INTO properties (object, key, val) VALUES %s',
                join(', ', map { sprintf '(?, ?, ?)' } @vals)
        );
        $sth->execute(map { $oid, @$_[1,2] } @vals);
        $sth->finish;
    }
}

sub db_remove_properties {
    my ($dbh, $o, @props) = @_;
    return if !@props;
    my $oid = db_oid($dbh, $o);
    my @criteria;
    my @params = ($oid);
    foreach (@props) {
        my ($op, $k, $v) = @$_;
        $op = OP_KEY if !defined $v && $op & OP_REMOVE;
        if ($op & (OP_SET|OP_REMOVE)) {
            if ($op & IS_REF) {
                push @criteria, '(key = ? AND ref IN (SELECT id FROM objects WHERE path = ?))';
            }
            else {
                push @criteria, '(key = ? AND val = ?)';
            }
            push @params, $k, $v;
        }
        elsif ($op & OP_KEY) {
            push @criteria, 'key = ?';
            push @params, $k;
        }
    }
    my $sql = sprintf 'DELETE FROM properties WHERE object = ? AND ( %s )',
        join(' OR ', @criteria);
    my $sth = $dbh->prepare($sql);
    $sth->execute(@params);
    $sth->finish;
}

#sub db_ensure_object {
#    my ($dbh, $path) = @_;
#    my $sth = $dbh->prepare('INSERT OR IGNORE INTO objects (path) VALUES (?)');
#    $sth->execute($path);
#    $sth->finish;
#}

sub db_bind {
    my ($dbh, $name, $obj) = @_;
    my $sth = $dbh->prepare('INSERT OR REPLACE INTO bindings(name, ref) VALUES (?, ?)');
    $sth->execute($name, db_object($dbh, $obj)->{'id'});
}

sub db_unbind {
    my ($dbh, $name) = @_;
    my $sth = $dbh->prepare('DELETE FROM bindings WHERE name = ?');
    $sth->execute($name);
}

sub db_bindings_from {
    my ($dbh, $name) = @_;
    my $sth = $dbh->prepare('SELECT ref FROM bindings WHERE name = ?');
    $sth->execute($name);
    my @paths;
    while (my ($ref) = $sth->fetchrow_array) {
        push @paths, db_path($dbh, $ref);
    }
    return @paths;
}

sub db_bindings_to {
    my ($dbh, $o) = @_;
    my $oid = db_oid($dbh, $o);
    my $sth = $dbh->prepare('SELECT name FROM bindings WHERE ref = ?');
    $sth->execute($oid);
    my @names;
    while (my ($name) = $sth->fetchrow_array) {
        push @names, $name;
    }
    return @names;
}

sub db_binding {
    my ($dbh, $name, $o) = @_;
    my $oid = db_oid($dbh, $o);
    my $sth = $dbh->prepare('SELECT 1 FROM bindings WHERE name = ? AND ref = ?');
    $sth->execute($name, $oid);
    my ($bound) = $sth->fetchrow_array;
    return !!$bound;
}

sub db_object {
    my ($dbh, $o, $check_only) = @_;
    return $o if ref $o;
    my ($sth, @params);;
    if ($o =~ m{^/}) {
        $sth = $dbh->prepare('SELECT id, path, parent FROM objects WHERE path = ?');
        @params = ($o);
    }
    elsif ($o =~ m{^[1-9][0-9]*$}) {
        $sth = $dbh->prepare('SELECT id, path, parent FROM objects WHERE id = ?');
        @params = ($o);
    }
    elsif ($o =~ m{^[@]([A-Za-z]\w*)$}) {
        @params = ($1);
        $sth = $dbh->prepare(q{
            SELECT  o.id, o.path, o.parent
            FROM    objects o JOIN bindings b ON o.id = b.ref
            WHERE   b.name = ?
        });
    }
    elsif ($o =~ m{^[@]([A-Za-z]\w*)(/.+)$}) {
        @params = ($1, $2);
        $sth = $dbh->prepare(q{
            SELECT  o2.id, o2.path, o2.parent
            FROM    objects o1, objects o2, bindings b
            WHERE   o1.id = b.ref
            AND     b.name = ?
            AND     o2.path = o1.path || ?
        });
    }
    else {
        die "unrecognized object: $o";
    }
    $sth->execute(@params);
    my $obj = $sth->fetchrow_hashref;
    $sth->finish;
    die "no such object: $o" if !$obj && !$check_only;
    return $obj;
}

sub db_oid {
    my ($dbh, $o) = @_;
    return $o->{'id'} if ref $o;
    return $o if $o =~ /^[1-9][0-9]*$/;
    return db_object($dbh, $o)->{'id'};
}

sub db_path {
    my ($dbh, $o) = @_;
    return $o->{'path'} if ref $o;
    return $o if $o =~ m{^/};
    return db_object($dbh, $o)->{'path'};
}

sub db_get_properties {
    my ($dbh, $o) = @_;
    my $oid = db_oid($dbh, $o);
    my $sth = $dbh->prepare('SELECT key, val, ref FROM properties WHERE object = ? ORDER BY key, val, ref');
    $sth->execute($oid);
    my @props;
    while (my ($k, $v, $r) = $sth->fetchrow_array) {
        if ($r) {
            push @props, [ OP_SET|IS_REF, $k, $r ];
        }
        elsif (defined $v) {
            push @props, [ OP_SET, $k, $v ];
        }
    }
    $sth->finish;
    return @props;
}

sub db_get_children {
    my ($dbh, $o) = @_;
    my $oid = db_oid($dbh, $o);
    my $sth = $dbh->prepare('SELECT * FROM objects WHERE parent = ?');
    $sth->execute($oid);
    my @children;
    while (my $child = $sth->fetchrow_hashref) {
        push @children, $child;
    }
    $sth->finish;
    return @children;
}

sub db_get_descendants {
    my ($dbh, $o) = @_;
    my $obj = db_object($dbh, $o);
    my $path = $obj->{'path'};
    my $sql = q{SELECT id, path FROM objects WHERE path LIKE ? ORDER BY path};
    my $sth = $dbh->prepare($sql);
    $path =~ s{^/+$}{};
    $sth->execute($path . '/_%');
    my @descendants;
    while (my $obj = $sth->fetchrow_hashref) {
        push @descendants, $obj;
    }
    $sth->finish;
    return @descendants;
}

sub db_get_bindings {
    my ($dbh, $o) = @_;
    my $obj = db_object($dbh, $o);
    my $sth = $dbh->prepare('SELECT name FROM bindings WHERE ref = ?');
    $sth->execute($obj->{'id'});
    my @names;
    while (my ($name) = $sth->fetchrow_array) {
        push @names, $name;
    }
    return @names;
}

sub db_find_objects {
    my $dbh = shift;
    my $root = db_object($dbh, shift);
    my (@parts, @params);
    foreach (@_) {
        my ($op, $k, $v) = @$_;
        if ($op & OP_SET) {
            if ($op & IS_REF) {
                push @parts, '(p.key = ? AND p.ref IN (SELECT id FROM objects WHERE path = ?))';
                push @params, $k, $v;
            }
            else {
                push @parts, '(p.key = ? AND p.val = ?)';
                push @params, $k, $v;
            }
        }
        elsif ($op & OP_KEY) {
            push @parts, '(p.key = ?)';
            push @params, $k;
        }
    }
    my $start = $root->{'path'};
    my $sql = sprintf 'SELECT o.id, o.path, o.parent, p.key FROM objects o INNER JOIN properties p ON o.id = p.object WHERE %s',
        join(' OR ', @parts);
    if ($start ne '/') {
        $sql .= ' AND o.path LIKE ?';
        push @params, $start . '%';
    }
    my $sth = $dbh->prepare($sql);
    $sth->execute(@params);
    my %match;
    my %object;
    while (my ($oid, $path, $parent, $key) = $sth->fetchrow_array) {
        $match{$oid}{$key}++;
        $object{$oid} ||= { 'id' => $oid, 'path' => $path, 'parent' => $parent };
    }
    my @objects;
    while (my ($oid, $matched) = each %match) {
        delete $object{$oid} if scalar(keys %$matched) != @parts;
    }
    return values %object;
}

# --- Functions

sub _init_sql_statements {
    split /;\n/, <<'EOS';
CREATE TABLE objects (
    id          INTEGER NOT NULL UNIQUE PRIMARY KEY,
    path        VARCHAR NOT NULL UNIQUE,
    parent      INTEGER NULL REFERENCES objects(id) ON DELETE CASCADE
);
CREATE TABLE properties (
    object      INTEGER NOT NULL,
    key         VARCHAR NOT NULL,
    val         VARCHAR,
    ref         INTEGER NULL REFERENCES objects(id) ON DELETE CASCADE
);
CREATE TABLE bindings (
    name        VARCHAR NOT NULL UNIQUE PRIMARY KEY,
    ref         INTEGER NOT NULL REFERENCES objects(id) ON DELETE CASCADE
);
CREATE UNIQUE INDEX objects_path_idx ON objects (path);
CREATE INDEX properties_obj_key_idx  ON properties (object, key);
CREATE INDEX properties_key_idx      ON properties (key);
CREATE INDEX properties_key_val_idx  ON properties (key, val);
CREATE INDEX properties_key_ref_idx  ON properties (key, ref);
CREATE INDEX bindings_name_idx       ON bindings (name);
INSERT INTO objects (id, path) VALUES (1, '/');
EOS
}

sub _props {
    my $modes = shift() || OP_ANY;
    my @props;
    while (@_) {
        my $x = shift @_;
        my $r = ref $x;
        if ($r eq '' && $x =~ /^([-+])?([@])?([A-Za-z0-9][-:._A-Za-z0-9]*)(?:=(.*))?$/) {
            my ($op, $k, $v) = ($op2int{$1||'='}, $3, $4);
            die if !($op & $modes);
            $op |= IS_REF if $2;
            if (!defined $v) {
                if ($op & OP_REMOVE) {
                    push @props, [ $op, $k ];
                }
                elsif ($modes & OP_KEY) {
                    push @props, [ OP_KEY, $k ];
                }
                else {
                    die if !@_;
                    $v = shift @_;
                    die if ref($v) ne '' && ref($v) ne 'ARRAY';
                    push @props, ref($v) eq 'ARRAY' ? map { [ $op, $k, $_ ] } @$v : [ $op, $k, $v ];
                }
            }
            else {
                push @props, [ $op, $k, $v ];
            }
        }
        elsif ($r eq 'ARRAY') {
            my ($op, $k, $v) = @$x;
            $op = $op2int{$op} || die "unrecognized op: $op";
            die if !($op & $modes);
            push @props, [ $op, $k, $v ];
        }
        elsif ($r eq 'HASH') {
            while (my ($k, $v) = each %$x) {
                my $op = ($k =~ s/^([+-])//) ? $op2int{$1} : OP_SET;
                die if !($op & $modes);
                push @props, ref($v) eq 'ARRAY' ? map { [ $op, $k, $_ ] } @$v : [ $op, $k, $v ];
            }
        }
        else {
            die;
        }
    }
    return @props;
}

sub _props_old {
    my $modes = shift() || OP_ANY;  # XXX Treat 0 as ~0
    my @props;
    foreach my $prop (@_) {
        $prop = _parse_prop($prop) if !ref $prop;
        die "not a permitted prop mode: $prop->[0]" if !($modes & $_->[0]);
        push @props, $prop;
    }
    return @props;
}

sub _parse_prop {
    local $_ = shift;
    /^([^-+=~!]+)([-+!]?[=~])(.*)$/
        or return [ OP_KEY, $_ ];
    my ($k, $op, $v) = ($1, $2, $3);
    return [ OP_SET,    $k, $v ] if $op eq '=';
    return [ OP_APPEND, $k, $v ] if $op eq '+=';
    return [ OP_REMOVE, $k, $v ] if $op eq '-=';
    die "invalid operator $op in key-value pair: $_";
}

sub _ancestor_paths {
    local $_ = shift;
    return if $_ eq '/';
    my @anc;
    while (s{(?<=.)/[^/]+$}{}) {
        push @anc, $_;
    }
    return ('/', reverse @anc);
}

sub init_plugins {
    my ($cls, $dir) = @_;
    foreach my $f (glob($dir . '/*.pm')) {
        warning("invalid plugin file name: $f"), next
            if $f !~ m{/([a-z]+)\.pm$};
        my ($name, $cls) = ($1, "App::sw::Plugin::$1");
        my $ok = eval {
            require $f;
            my $plugin = $cls->new('app' => $app);
            my %c = eval { $plugin->commands };
            my %h = eval { $plugin->hooks };
            while (my ($cmd, $sub) = each %c) {
                die "plugin $name provides command $cmd but it is already provided"
                    if exists $command{$cmd};
                $command{$cmd} = sub { $sub->($plugin) };
            }
            while (my ($hook, $sub) = each %h) {
                die "plugin $name provides hook $hook but it is already provided"
                    if exists $hook{$hook};
                $hook{$hook} = sub { $sub->($plugin) };
            }
            1;  # OK
        };
        die "can't load plugin $name: ", (split /\n/, $@)[0] if !$ok;
    }
}

sub orient {
    my $self = shift;
    goto &App::sw::main::orient;
}

# --- Testing code

sub test {
    my $dbfile = @ARGV ? shift @ARGV : 'test.db';
    my $app;
    if (-e $dbfile) {
        $app = App::sw->open($dbfile);
    }
    else {
        $app = App::sw->create($dbfile);
        $app->insert('/user/fishwick',
            'name' => 'Ulysses K. Fishwick',
            'age' => '3',
            'nick' => 'fishwick',
        );
        $app->bind('fishwick', '/user/fishwick');
        $app->insert('/user/fishwick/home/foo',
            'foo' => 'bar',
            'friend' => 'sid',
            'friend' => 'nancy',
        );
        1;
    }
    @ARGV = ('@fishwick/home/foo') if !@ARGV;
    foreach (@ARGV) {
        my $obj = $app->object($_);
        my @props = $app->get($obj);
        print $obj->{'path'}, "\n";
        foreach (@props) {
            print join('=', @$_), "\n";
        }
        print "\n";
    }
}

