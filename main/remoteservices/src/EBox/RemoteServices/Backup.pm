# Copyright (C) 2008-2012 eBox Technologies S.L.
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

package EBox::RemoteServices::Backup;
use base 'EBox::RemoteServices::Cred';

use strict;
use warnings;

use Data::Dumper;
use Error qw(:try);
use EBox::Backup;
use EBox::Config;
use EBox::Exceptions::DataNotFound;
use EBox::Exceptions::Internal;
use EBox::Gettext;
use EBox::Global;
use EBox::RemoteServices::Cred;
use File::Glob ':globally';
use File::Slurp;
use File::Temp;
use LWP::UserAgent;
use URI;
use HTTP::Status;
use v5.10;

# Constants
use constant CURL => 'curl';

# Group: Public methods

# Constructor: new
#
#     Construct a new <EBox::RemoteServices::Backup> object
#
sub new
{
    my ($class, @params) = @_;

    my $self = $class->SUPER::new(@params);

    bless($self, $class);

    # TODO: Do not hardcode
    $self->{cbServer} = 'confbackup.' . $self->cloudDomain();
    # Customise RESTClient
    $self->{restClient}->setServer($self->{cbServer});

    return $self;
}

sub prepareMakeRemoteBackup
{
    my ($self, $name, $description) = @_;
    $name or throw EBox::Exceptions::MissingArgument('name');
    defined $description or $description = '';


    my @backupOptions = (
        description => $description,
        remoteBackup => $name,
       );

    return EBox::Backup->prepareMakeBackup(@backupOptions);
}

# Method: makeRemoteBackup
#
#      Make a configuration backup and send it to Zentyal Cloud
#
# Parameters:
#
#      name - String the backup's name
#
#      description - String the backup's description
#
#      automatic - Boolean indicating whether the backup must be set as
#                  automatic or not
#
sub makeRemoteBackup
{
    my ($self, $name, $description, $automatic) = @_;

    $name or throw EBox::Exceptions::MissingArgument('name');
    defined $description or $description = '';

    my @backupOptions = (
        description  => $description,
        fallbackToRO => $automatic,
       );

    my $archive = EBox::Backup->makeBackup(@backupOptions);

    $self->sendRemoteBackup($archive, $name, $description, $automatic);
}


# Method: sendRemoteBackup
#
#      Send a configuration backup to Zentyal Cloud
#
# Parameters:
#
#      archive - String the path to the configuration backup archive
#
#      name - String the backup's name
#
#      description - String the backup's description
#
#      automatic - Boolean indicating whether the backup must be set as
#                  automatic or not
#
sub sendRemoteBackup
{
    my ($self, $archive, $name, $description, $automatic) = @_;
    $archive or throw EBox::Exceptions::MissingArgument('archive');
    $name    or throw EBox::Exceptions::MissingArgument('name');
    defined $description or $description = '';
    defined $automatic or $automatic = 0;

    try {
        $self->_pushConfBackup($archive,
                               fileName => $name,
                               comment => $description,
                               automatic => $automatic,
                               size => (-s $archive));
    }
    finally {
        unlink $archive;
    };
}

# Restore remote configuration backup
sub restoreRemoteBackup
{
    my ($self, $name) = @_;
    $name or throw EBox::Exceptions::MissingArgument('name');

    my $archiveFile = $self->downloadRemoteBackup($name);

    try {
        EBox::Backup->restoreBackup($archiveFile);
    } finally {
        if (-e $archiveFile) {
            unlink($archiveFile);
        }
    };
}


sub prepareRestoreRemoteBackup
{
    my ($self, $name, $dr) = @_;
    $name or throw EBox::Exceptions::MissingArgument('name');

    my $archiveFile = $self->downloadRemoteBackup($name);
    my $progress;

    try {
        $progress = EBox::Backup->prepareRestoreBackup(
            $archiveFile,
            fullRestore => 0,
            deleteBackup => 1,
            dr => $dr,
        );
    } otherwise {
        my ($ex) = @_;
        unlink($archiveFile);
        $ex->throw();
    };

    return $progress;
}

# Return the configuration backup file path
sub downloadRemoteBackup
{
    my ($self, $name, $fh) = @_;
    $name or throw EBox::Exceptions::MissingArgument('name');

    my $archive = $self->_pullConfBackup(fileName => $name,
                                         fh => $fh);
    return $archive;
}

sub removeRemoteBackup
{
    my ($self, $name) = @_;
    $name or throw EBox::Exceptions::MissingArgument('name');

    $self->_removeConfBackup(fileName => $name);
}

# Method: listRemoteBackups
#
#       Get the list of the current remote configuration backups
#
# Returns:
#
#       hash ref - the list of backups indexed by name with the following values:
#
#           Automatic - 1/0 indicating whether the backup is automatic or not
#           Canonical Name - String with the server name
#           Comment - String the description for the backup
#           Date - String the date in printable format
#           sortableDate - Int the date in seconds from epoch
#           Filename - String the backup name
#           Size - Int the size in bytes
#           printableSize - String the size in a printable format
#
sub listRemoteBackups
{
    my ($self) = @_;

    my $metainfo;
    try {
        my $footprint = $self->_pullFootprintMetaConf();
        if ($footprint eq $self->_metainfoFootprint()) {
            $metainfo = $self->_metainfoFromCache();
        } else {
            $metainfo = $self->_metainfoFromServer();
            $self->_setMetainfoFootprint($footprint);
            $self->_setMetainfoCache($metainfo);
        }
    } catch EBox::Exceptions::DataNotFound with {
        # If all.info does not exist, fill fields artificially
        $self->_setMetainfoFootprint('');
        $self->_setMetainfoCache({});
    };

    return $metainfo;
}

sub remoteBackupInfo
{
    my ($self, $name) = @_;

    my $allBackups = $self->listRemoteBackups();
    exists $allBackups->{$name} or
      throw EBox::Exceptions::External(
          __x('Inexistent backup: {n}', n => $name)
         );
    return  $allBackups->{$name};
}

# Group: Private methods

sub _metainfoFromServer
{
    my ($self) = @_;

    my $metainfo = {};
    my $metainfoStr = $self->_pullAllMetaConfBackup();

    my @elements = split '\n\s*\n', $metainfoStr;
    foreach my $element (@elements) {
        my %properties;

        my @lines = split '\n', $element;
        foreach my $line (@lines) {
            # The pattern specified is fieldName: fieldValue
            my ($name, $value) = split(':', $line, 2);
            $value or next;

            $value =~ s/^\s+//; # remove suprefluous spaces at the begin
            $properties{$name} = $value;
        }

        if (not exists $properties{Filename}) {
            throw EBox::Exceptions::Internal("Missing 'Filename' field");
        }

        if (exists $properties{Size}) {
            $properties{printableSize} =
              $self->_printableSize($properties{Size});
        }

        if (exists $properties{Date}) {
            $properties{sortableDate} = $self->_sortableDate($properties{Date});
        }

        $metainfo->{$properties{Filename}} = \%properties;
    }

    return $metainfo;
}

sub _metainfoFile
{
    return EBox::Config::tmp() . '/backup-service-metainfo';
}

sub _metainfoFromCache
{
    my ($self) = @_;

    my $file = $self->_metainfoFile();
    my $metainfoDump = File::Slurp::read_file($file);

    my $VAR1;                   # variable used by  Data::Dumper
    eval $metainfoDump;

    return $VAR1;
}

sub _setMetainfoCache
{
    my ($self, $metainfo) = @_;

    my $file = $self->_metainfoFile();
    my $metainfoDump = Dumper($metainfo);
    return File::Slurp::write_file($file, $metainfoDump);
}

sub _metainfoFootprintFile
{
    return EBox::Config::tmp() . '/backup-service-metainfo.footprint';
}

sub _metainfoFootprint
{
    my ($self) = @_;

    my $file = $self->_metainfoFootprintFile();
    if (not -r $file) {
        return '';
    }

    return File::Slurp::read_file($file);
}

sub _setMetainfoFootprint
{
    my ($self, $footprint) = @_;

    my $file = $self->_metainfoFootprintFile();
    return File::Slurp::write_file($file, $footprint);

}

sub _pushConfBackup
{
    my ($self, $archive, %p) = @_;

    my $ret = $self->{restClient}->PUT('/conf-backup/meta/' . $p{fileName}, query => \%p, retry => 0);

    # Send the file using curl
    my $url = new URI('https://' . $self->{cbServer} . '/conf-backup/put/' . $p{fileName});

    my $curlCmd = CURL;
    $curlCmd .= ' --insecure' unless ( EBox::Config::boolean('rs_verify_servers') );
    $curlCmd .= " --upload-file '$archive' --netrc '" . $url->as_string() . "'";
    EBox::Sudo::command($curlCmd);
}

sub _handleResult   # ( HTTP::Response, named params)
{
    my ($res, %p) = @_;

    unless ( $res->code == HTTP::Status::HTTP_OK ) {
        #Throw the proper exception for each error code

        given ( $res->code ) {
            when (HTTP::Status::HTTP_NOT_FOUND) {
                throw EBox::Exceptions::Internal(__('Server not found'));
            } when (HTTP::Status::HTTP_NO_CONTENT) {
                throw EBox::Exceptions::DataNotFound(
                    data => __('Configuration backup'),
                    value => $p{fileName}
                    );
            } when (HTTP::Status::HTTP_BAD_REQUEST) {
                throw EBox::Exceptions::Internal(__('Some argument is missing'));
            } when (HTTP::Status::HTTP_INTERNAL_SERVER_ERROR) {
                throw EBox::Exceptions::Internal(__('Internal Server Error'));
            } when (HTTP::Status::HTTP_FORBIDDEN) {
                throw EBox::Exceptions::Internal(__('Forbidden request'));
            } default {
                throw EBox::Exceptions::Internal(__('An error has occurred'));
            }
        }
    }
}

# Method: _pullConfBackup
#
#     Pull the configuration backup from Zentyal Cloud
#
# Named parameters:
#
#    fileName - String the file name to retrieve
#    fh       - Filehandle if given, then the conf backup is written there
#
# Returns:
#
#    String - the path to the configuration backup if fh is not given
#
#    undef  - otherwise
#
sub _pullConfBackup
{
    my ($self, %p) = @_;

    my $url = new URI('https://' . $self->{cbServer} . '/conf-backup/get/' . $p{fileName});

    my $ua = new LWP::UserAgent();
    $ua->ssl_opts('verify_hostname' => EBox::Config::boolean('rs_verify_servers'));

    my $req = HTTP::Request->new(GET => $url->as_string());
    $req->authorization_basic($self->{restClient}->{credentials}->{username},
                              $self->{restClient}->{credentials}->{password});
    if ( exists $p{fh} and defined $p{fh} ) {
        my $fh = $p{fh};
        # Perform the query with fh as destination
        my $res = $ua->request($req,
                               sub {
                                   my ($chunk, $res) = @_;
                                   print $fh $chunk;
                               });

        _handleResult($res, %p);

        return undef;
    } else {
        my $outFile = EBox::Config::tmp() . 'pull-conf.backup';
        my $res = $ua->request($req, $outFile);

        _handleResult($res, %p);

        return $outFile;
    }
}


sub _pullAllMetaConfBackup
{
    my ($self, %p) = @_;

    my $res = $self->{restClient}->GET('/conf-backup/meta/all/', query => \%p, retry => 0);

    _handleResult($res->{result}, %p);

    return $res->as_string();
}

sub _pullFootprintMetaConf
{
    my ($self, %p) = @_;

    my $res = $self->{restClient}->GET('/conf-backup/meta/footprint/', query => \%p, retry => 0);

    _handleResult($res->{result}, %p);

    return $res->as_string();
}

sub _removeConfBackup
{
    my ($self, %p) = @_;

    my $res = $self->{restClient}->DELETE('/conf-backup/meta/' . $p{fileName}, retry => 0);

    _handleResult($res->{result}, %p);
}

1;
