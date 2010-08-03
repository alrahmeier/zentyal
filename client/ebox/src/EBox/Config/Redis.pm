# Copyright (C) 2010 eBox Technologies S.L.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License, version 2, as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

package EBox::Config::Redis;

use 5.010001;
use strict;
use warnings;

use Redis;
use EBox::Service;
use YAML::Tiny;
use XML::Simple;
use File::Slurp;
use Error qw/:try/;

my $redis = undef;
use constant REDIS_CONF => '/var/lib/ebox/conf/redis.conf';

sub new
{
    my ($class, %args) = @_;

    my $self = {};
    bless($self, $class);

    # Launch daemon if it does not exists
    unless (defined $redis) {
        $self->_initRedis;
        $self->_respawn;
    }
    $self->{redis} = $redis;
    $self->{pid} = $$;

    return $self;
}

# Method: set_string
#
#   Set key to $value
#
sub set_string
{
    my ($self, $key, $value) = @_;

   $self->_redis_call('set', $key =>  $value);
}

# Method: get_string
#
#   Fetch the value stored in key
#
sub get_string
{
    my ($self, $key) = @_;

    return $self->_redis_call('get', $key);
}

# Method: set_int
#
#   Set $key to $value
#
sub set_int
{
    my ($self, $key, $value) = @_;

    $self->set_string($key => $value);
}

# Method: get_int
#
#   Fetch the value stored in $key
#
sub get_int
{
    my ($self, $key) = @_;

    return $self->get_string($key);
}

# Method:  set_bool
#
#   Set I$key to $value
#
sub set_bool
{
    my ($self, $key, $value) = @_;

    $self->set_string($key => $value ? 1 : 0);
}

# Method: get_bool
#
#    Fetch the value stored in $key
#
sub get_bool
{
    my ($self, $key) = @_;

    return $self->get_string($key);
}

# Method: set_list
#
#   Set $key to $list. Where $list is an array ref.
#
sub set_list
{
    my ($self, $key, $list) = @_;
    $self->_redis_call('del', $key);
    for my $value (@{$list}) {
        $self->_redis_call('rpush', $key, $value);
    }
}

# Method: get_list
#
#   Fetch the array ref stored in $key
#
sub get_list
{
    my ($self, $key) = @_;

    unless ($self->exists($key)) {
        return [];
    }
    return [$self->_redis_call('lrange', $key, 0, -1)];
}

# Method: all_dirs
#
#   Return an array ref contaning all the directories in $key
#
sub all_dirs
{
    my ($self, $key) = @_;

    my $length = length $key;
    my %dir;
    for my $path ($self->_redis_call('keys', "$key*")) {
        my $index = index($path, '/', $length + 1);
        if ($index > 0) {
            my $directory = substr($path, 0, $index);
            $dir{$directory} = undef;
        }
    }
    return [keys %dir];
}

# Method: all_entries
#
#   Return an array ref contaning all the entries in $key
#
sub all_entries
{
    my ($self, $key) = @_;

    my $length = length $key;
    my @dirs;
    for my $path ($self->_redis_call('keys', "$key*")) {
        push (@dirs, $path) if (index($path, '/', $length + 1) == -1);
    }
    return \@dirs;
}

# Method: dir_exists
#
#   Returns true if the given directory exists in the loaded configuration.
#
sub dir_exists
{
    my ($self, $dir) = @_;

    my @keys = $self->_redis_call('keys', "${dir}/*");
    return (@keys > 0);
}

# Method: delete_dir
#
#   Delete a directory recursively
#
sub delete_dir
{
    my ($self, $dir) = @_;

    return unless ($self->dir_exists($dir));
    for my $entry (@{$self->all_entries($dir)}) {
        $self->unset($entry);
    }
    for my $subdir (@{$self->all_dirs($dir)}) {
        $self->delete_dir($subdir);
    }
}

# Method: unset
#
#   Unset a key
#
sub unset
{
    my ($self, $key) = @_;

    $self->_redis_call('del', $key);
}

# Method: exists
#
#   Check if a given key exists
#
sub exists
{
    my ($self, $key) = @_;

    $self->_redis_call('exists', $key);
}

# Method: backup_dir
#
#   Back up a given dir $key in $dest
#
sub backup_dir
{
    my ($self, $key, $dest) = @_;

    $self->delete_dir($dest);
    $self->_backup_dir(
        key => $key,
        destination_type => 'redis',
        destination => $dest
    );
}

# Method: restore_dir
#
#   Restore orig/$key in $dest
#
sub restore_dir
{
    my ($self, $key, $orig, $dest) = @_;

    $self->delete_dir($dest . $key);
    $self->_restore_dir($key, $orig, $dest);
}


# Method: export_dir_to_yaml
#
#   Back up a given dir in YAML file
#
# Parameters:
#
#   key - key for the directory
#   file - yaml file to write
#
sub export_dir_to_yaml
{
    my ($self, $key, $file) = @_;

    my @keys;
    $self->_backup_dir(
        key => $key,
        destination_type => 'yaml',
        destination => \@keys
    );
    try {
        YAML::Tiny::DumpFile($file, @keys);
    } otherwise {
        throw EBox::Exceptions::External("Error dumping $key to YAML:$file");
    };
}


# Method: import_dir_from_yaml
#
#   Given a YAML file, restore all its keys/values under destination folder
#
# Parameters:
#
#   filename - YAML filename
#   dest - destination folder key
#
sub import_dir_from_yaml
{
    my ($self, $filename, $dest) = @_;

    my @keys;

    try {
        @keys = YAML::Tiny::LoadFile($filename);
    } otherwise {
        throw EBox::Exceptions::External("Error parsing YAML:$filename");
    };

    for my $entry (@keys) {
        my $value = $entry->{value};
        my $key;
        if ($dest) {
            $key = $dest . $entry->{key};
        } else {
            $key = $entry->{key};
        }
        if ($entry->{type} eq 'string') {
            $self->set_string($key, $value);
        } else {
            $self->set_list($key, $value);
        }
    }
}



# Method: import_dir_from_gconf
#
#   Given a Gconf Dump XMP file, restore all its keys/values under destination folder
#
# Parameters:
#
#   filename - XML filename
#   dest - destination folder key
#
sub import_dir_from_gconf
{
    my ($self, $filename, $dest) = @_;

    my $data;
    try {
        my $xml = new XML::Simple(ForceArray => ['entry', 'list/value']);
        $data = $xml->XMLin($filename);
    } otherwise {
        throw EBox::Exceptions::External("Error parsing XML:$filename");
    };

    # parse array converted from gconf format XML file
    my $entrylist = $data->{entrylist};
    my $base = $entrylist->{base};

    for my $key ( keys %{$entrylist->{entry}} ) {
        my $entry = $entrylist->{entry}->{$key};

        my $type = (keys %{$entry->{value}})[0];
        my $value = $entry->{value}->{$type};

        $key = $base . '/' . $key;
        if ($dest) {
            $key = $dest . $key;
        }

        if ($type eq 'list') {
            # list value, get elements

            $value = $value->{value};
            my @list = ();
            if ( ref $value eq 'HASH' ) {
                my $type = (keys %{$value})[0];
                my $value = $value->{$type};
                push (@list, $value);
            } else {
                for my $item (@{$value}) {
                    my $key = (keys %{$item})[0];
                    my $value = $item->{$key};
                    push (@list, $value);
                }
            }
            $self->set_list($key, \@list);
        } else {
            # scalar value, save as string
            $self->set_string($key, $value);
        }
    }
}


sub _import_list
{
    my ($self) = @_;

}


sub _backup_dir
{
    my ($self, %args) = @_;

    my $key = $args{key};
    my $destinationType = $args{destination_type};
    my $dest = $args{destination};

    for my $entry (@{$self->all_entries($key)}) {
        my $type = $self->_redis_call('type', $entry);
        my $destKey = $entry;
        if ($destinationType eq 'redis') {
            $destKey = $dest . substr($destKey, length($key));
        }
        if ($type eq 'string') {
            my $value = $self->get_string($entry);
            if ($destinationType eq 'redis') {
                $self->set_string(
                    $destKey,
                    $value,
                 );
            } else {
                push (@{$args{destination}},
                        {
                            type => 'string',
                            key => $destKey,
                            value => $value
                        }
                );
            }
        } elsif ($type eq 'list') {
            my $list = $self->get_list($entry);
            if ($destinationType eq 'redis') {
                $self->set_list(
                    $destKey,
                    $list
                );
            } else {
                push (@{$args{destination}},
                        {
                            type => 'list',
                            key => $destKey,
                            value => $list
                        }
                );
            }
        }
    }

    my $destKey = $dest;
    for my $subdir (@{$self->all_dirs($key)}) {
        if ($destinationType eq 'redis') {
            $destKey = $dest . substr($subdir, length($key));
        }
        $self->_backup_dir(
            key => $subdir,
            destination => $destKey,
            destination_type => $destinationType
        );
    }
}

sub _restore_dir
{
    my ($self, $key, $orig, $dest) = @_;

    for my $entry (@{$self->all_entries($orig . $key)}) {
        my $type = $self->_redis_call('type', $entry);
        my $destKey = $dest . substr($entry, length($orig));
        if ($type eq 'string') {
            $self->set_string(
                $destKey,
                $self->get_string($entry)
            );
        } elsif ($type eq 'list') {
            my $list = $self->get_list($entry);
            $self->set_list(
                $destKey,
                $list
            );
        }
    }
    for my $subdir (@{$self->all_dirs($orig. $key)}) {
        $self->_restore_dir(substr($subdir, length($orig)), $orig, $dest);
    }
}

# Wrapper to reconnect to to redis in case of detecting a failure when
# issuing a command.
sub _redis_call
{
    my ($self, $command, @args) = @_;

    # Check process id and respawn redis if has changed (fork)
    if ( $self->{pid} ne $$ ) {
        $self->_respawn;
    }

    my $response;
    my @response;
    my $wantarray = wantarray;
    for my $i (0..1) {
        my $failure;
        try {
            if ($wantarray) {
                @response = $self->{redis}->$command(@args);
            } else {
                $response = $self->{redis}->$command(@args);
            }
            $failure  = 0;
        } otherwise {
            # Disconnected, try to reconnect
            $self->_initRedis;
            $self->_respawn;
            $failure = 1;
        };

        last unless ($failure);

        if ($failure and $i == 0) {
            warn 'Reconnecting to redis server...'
        } elsif ($failure and $i == 1) {
            die 'Cannot connect to redis server';
        }
    }

    if ($wantarray) {
        return @response;
    } else {
        return $response;
    }
}

# Reconnect to redis server
sub _respawn
{
    my ($self) = @_;
    $self->{redis} = undef;
    $redis = undef;

    my $port = EBox::Config::configkey('redis_port');
    my $filepasswd = $self->_passwd();

    $redis = Redis->new(server => "127.0.0.1:$port");
    $redis->auth($filepasswd);
    $self->{redis} = $redis;
    $self->{pid} = $$;
}


# Initialize redis daemon if it's not running
sub _initRedis
{
    my ($self) = @_;

    my $firstInst = ( -f '/var/lib/ebox/redis.first' );
    return if ($firstInst); # server considered running on first install

    unless ( EBox::Service::running('ebox.redis') ) {
        EBox::info('Starting redis server');

        # Write redis daemon conf file
        my $port = EBox::Config::configkey('redis_port');
        my $filepasswd = $self->_passwd();

        my @groups = @{EBox::Config::groups()};
        my $gids = '';
        for my $group (@groups) {
            $gids .= getgrnam($group) . ' ';
        }
        my $gid = getgrnam(EBox::Config::group());
        my $uid = getpwnam(EBox::Config::user());

        my @params = ();
        push (@params, home_dir => EBox::Config::home());
        push (@params, port => $port);
        push (@params, passwd => $filepasswd);
        EBox::Module::Base::writeConfFileNoCheck(REDIS_CONF, '/redis.conf.mas' , \@params, {mode => '0600', uid => $uid, gid => $gid});

        # Launch daemon, added sleep to avoid first connection problems
        EBox::Sudo::silentRoot('start ebox.redis && sleep 1');
    }
}

# Stop redis server, sync changes to disk before
sub stopRedis
{
    my ($self) = @_;
    $self->_redis_call('save');
    EBox::Service::manage('ebox.redis', 'stop');
}


# Returns redis server password
sub _passwd
{
    return read_file('/var/lib/ebox/conf/redis.passwd') or
        throw EBox::Exceptions::External('Could not open passwd file');
}

1;
