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

package EBox::SysInfo::Composite::General;

use base 'EBox::Model::Composite';

use strict;
use warnings;

use EBox::Gettext;
use EBox::Global;

# Group: Public methods

# Constructor: new
#
#   Constructor for the general events composite
#
# Returns:
#
#   <EBox::Samba::Model::General> - a
#       general events composite
#
sub new
{
    my ($class, @params) = @_;

    my $self = $class->SUPER::new(@params);

    return $self;
}

# Method: componentNames
#
# Overrides:
#
#     <EBox::Model::Composite::componentNames>
#
sub componentNames
{
    my ($self) = @_;

    my @components;

    my $rs = EBox::Global->modInstance('remoteservices');
    if (defined ($rs) and $rs->subscriptionLevel() > 0) {
        push (@components, 'sysinfo/ManageAdmins');
    } else {
        push (@components, 'sysinfo/AdminUser');
    }

    push (@components, 'apache/Language',
                       'sysinfo/TimeZone',
                       'sysinfo/DateTime',
                       'apache/AdminPort',
                       'sysinfo/HostName');

    return \@components;
}

# Group: Protected methods

# Method: _description
#
# Overrides:
#
#   <EBox::Model::Composite::_description>
#
sub _description
{
    my $description = {
                        layout          => 'top-bottom',
                        name            => __PACKAGE__->nameFromClass,
                        printableName   => __('General configuration'),
                        pageTitle       => __('General configuration'),
                        compositeDomain => 'SysInfo',
                        help => __('On this page you can set different general system settings')
    };

    return $description;
}

1;
