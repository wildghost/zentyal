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

package EBox::Service;

use strict;
use warnings;

use EBox::Sudo;

#   Function: manage
#
#   Manage daemons
#
#   Parameters:
#
#       daemon - name of the daemon
#       action - [start|stop|restart]
#
#   Exceptions:
#
#       Internal - Bad argument
#
sub manage # (daemon,action)
{
    my ($daemon, $action) = @_;
    (-f "/etc/init/$daemon.conf") or
        throw EBox::Exceptions::Internal("No such daemon: $daemon");

    if ( $action eq 'start' ) {
        EBox::Sudo::root("start '$daemon'");
    }
    elsif ( $action eq 'stop' ) {
        EBox::Sudo::root("stop '$daemon'") if (running($daemon));
    }
    elsif ( $action eq 'restart') {
        EBox::Sudo::root("stop '$daemon'") if (running($daemon));
        EBox::Sudo::root("start '$daemon'");
    }
    else {
        throw EBox::Exceptions::Internal("Bad argument: $action");
    }
}

#   Function: running
#
#   Check if a daemon is running
#
#   Parameters:
#
#       daemon - name of the daemon
#
#   Exceptions:
#
#       <EBox::Exceptions::Internal> - Bad argument
#
sub running # (daemon)
{
    my ($daemon) = @_;
    (-f "/etc/init/$daemon.conf") or
        throw EBox::Exceptions::Internal("No such daemon: $daemon");

    my $status = `status '$daemon'`;
    # TODO: Parse different exit status:
    #       Pre-start
    #       Post-start
    #       ....
    #       Not it's running or stopped
    if ($status =~ m{^$daemon start/running.*}) {
        return 1;
    } else {
        return undef;
    }
}

1;
