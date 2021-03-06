# Copyright (C) 2012 eBox Technologies S.L.
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

package EBox::UsersSync::Master;

use strict;
use warnings;

use EBox::Config;
use EBox::Exceptions::External;
use EBox::Util::Random;
use EBox::Sudo;
use EBox::SOAPClient;
use EBox::Gettext;
use URI::Escape;
use File::Slurp;
use EBox::UsersSync::Slave;
use Error qw(:try);

# File containing password for master's web service (to register a new slave)
use constant MASTER_PASSWORDS_FILE => EBox::Config::conf() . 'users/master.htaccess';

# Dir containing certificates for this master
use constant SSL_DIR => EBox::Config::conf() . 'ssl/';

# Certificate of the authorized master
use constant MASTER_CERT => '/var/lib/zentyal/conf/users/master.cert';

sub new
{
    my $class = shift;
    my $self = {};
    bless($self, $class);
    return $self;
}

# Method: confSOAPService
#
#   Configure SOAP service to allow Master and Slave queries
#
sub confSOAPService
{
    my ($self) = @_;

    my $confFile = EBox::Config::conf() . 'users/soap.conf';

    my @params;
    push (@params, passwords_file => MASTER_PASSWORDS_FILE);

    EBox::Module::Base::writeConfFileNoCheck($confFile, 'users/soap.mas', \@params);

    my $apache = EBox::Global->modInstance('apache');
    $apache->addInclude($confFile);

    $apache->addCA(MASTER_CERT) if (-f MASTER_CERT);
}


# SERVER METHODS

# Method: getCertificate
#
#   Return Master certificate (to be used when connecting to the slave's SOAP)
#
sub getCertificate()
{
    my ($self) = @_;

    return read_file(SSL_DIR . 'ssl.cert');
}

# Method: setupMaster
#
#   Setup master server to allow new slaves connections
#
sub setupMaster
{
    my ($self, $pass) = @_;

    defined $pass or
        $pass = EBox::Util::Random::generate(15);

    my $users = EBox::Global->getInstance()->modInstance('users');
    my $table = $users->model('SlavePassword');

    my $row = $table->row();
    $row->elementByName('password')->setValue($pass);
    $row->store();

    EBox::Sudo::root(
        'rm -f ' . MASTER_PASSWORDS_FILE,
        'htpasswd -bc ' . MASTER_PASSWORDS_FILE . ' slave ' . $pass,
    );
}


# Method: addSlave
#
#   Register a new slave in this master
#
#
sub addSlave
{
    my ($self, $host, $port, $cert) = @_;

    my $users = EBox::Global->modInstance('users');
    my $table = $users->model('Slaves');

    EBox::info("Adding a new slave on $host:$port");


    my $changed = $users->changed();
    my $id = $table->addRow(host => $host, port => $port);

    unless ($changed) {
        # FIXME do this better when framework available
        $users->_saveConfig();
        $users->setAsChanged(0);
    }

    unless (-d EBox::UsersSync::Slave->SLAVES_CERTS_DIR) {
        mkdir EBox::UsersSync::Slave->SLAVES_CERTS_DIR;
    }

    # save slave's cert
    write_file(EBox::UsersSync::Slave->SLAVES_CERTS_DIR . $id, $cert);

    $users->initialSlaveSync(new EBox::UsersSync::Slave($host, $port, $id));

    # Regenerate slave connection password
    $self->setupMaster();
}


# CLIENT METHODS

# Method: checkMaster
#
#   Checks connection to a given master's SOAP
#
# Parameters:
#
#   host - master hostname or ip
#   port - master administration port
#   password - password for slave connection
#
# Returns 1 if could connect and SOAP replied, 0 otherwise
#
sub checkMaster
{
    my ($self, $host, $port, $password) = @_;

    my $apache = EBox::Global->modInstance('apache');
    my $users = EBox::Global->modInstance('users');
    $password = uri_escape($password);
    local $ENV{PERL_LWP_SSL_VERIFY_HOSTNAME} = 0;
    my $master = EBox::SOAPClient->instance(
        name  => 'urn:Users/Master',
        proxy => "https://slave:$password\@$host:$port/master",
    );


    try {
        $master->getDN();
    } otherwise {
        my $ex = shift;
        $self->_analyzeException($ex);
    };

    # Check that master's REALM is correct
    $self->_checkRealm($users, $master);
}


# Method: isSlave
#
#   Return 1 if already configured as slave
#
sub isSlave
{
    my ($self) = @_;

    return (-f MASTER_CERT);
}

# Method: setupSlave
#
#   Configure users module as slave of a given master host
#
sub setupSlave
{
    my ($self) = @_;

    my $users = EBox::Global->modInstance('users');
    my $master = $users->model('Master');

    if ($users->master() eq 'zentyal') {
        # return if already configured
        return if ($self->isSlave());

        my $host = $master->hostValue();
        my $port = $master->portValue();
        my $password = $master->passwordValue();

        my $apache = EBox::Global->modInstance('apache');
        $password = uri_escape($password);
        my $client = EBox::SOAPClient->instance(
            name  => 'urn:Users/Master',
            proxy => "https://slave:$password\@$host:$port/master",
        );

        # Recreate LDAP for the master DN
        $self->_recreateLDAP($users, $client);

        # get master's certificate
        my $cert = $client->getCertificate();

        my $client_cert = read_file(SSL_DIR . 'ssl.cert');
        try {
            $client->registerSlave($apache->port(), $client_cert, 1);
        } otherwise {
            my $ex = shift;
            $self->_analyzeException($ex);
        };

        # Write master certificate
        # (after registering slave, this means everything went well)
        write_file(MASTER_CERT, $cert);
    }
    else {
        # return if already disabled
        return unless ($self->isSlave());

        # disable master access
        unlink (MASTER_CERT);
    }
}


sub _checkRealm
{
    my ($self, $users, $client) = @_;

    my $mrealm = $client->getRealm();
    my $srealm = $users->kerberosRealm();

    unless ($srealm eq $mrealm) {
        throw EBox::Exceptions::External(__x("Master server has a different REALM, check hostnames. Master is {master} and slave {slave}.", master => $mrealm, slave => $srealm));
    }
}


sub _recreateLDAP
{
    my ($self, $users, $client) = @_;

    my $dn = $client->getDN();

    my $row = $users->model('Mode')->row();
    $row->elementByName('dn')->setValue($dn);
    $row->store();

    # Enable actions (without slave setup to avoid recursion)
    $users->enableActions();

    # TODO: reenable all LDAP modules
}

sub _analyzeException
{
    my ($self, $ex) = @_;

    my $msg = $ex->text();
    if ($msg =~ m/^401/) {
        $msg = __('Invalid password');
    }
    elsif ($msg =~ m/^500/) {
        $msg = __('Connection failed, check host, port and firewall settings');
    }
    throw EBox::Exceptions::External(__("Couldn't configure Zentyal as slave") . ": $msg.");
}


1;
