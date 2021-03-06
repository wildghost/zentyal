# Copyright (C) 2009-2011 eBox Technologies S.L.
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

package EBox::CGI::EGroupware::EGroupwareGroupOptions;

use strict;
use warnings;

use base 'EBox::CGI::ClientBase';

use EBox::Global;
use EBox::Gettext;
use EBox::EGroupwareLdapUser;

## arguments:
##  title [required]
sub new {
    my $class = shift;
    my $self = $class->SUPER::new('title' => 'EGroupware',
                      @_);
    $self->{domain} = "ebox-egroupware";

    bless($self, $class);
    return $self;
}

sub _process($) {
    my $self = shift;
    my $egwldap = new EBox::EGroupwareLdapUser;

    $self->_requireParam('groupname', __('groupname'));
    my $groupname = $self->param('groupname');
    $self->{redirect} = "UsersAndGroups/Group?group=$groupname";

    $self->keepParam('groupname');

    if (defined($self->param('template'))) {
        $egwldap->setGroupTemplate($groupname, $self->param('template'));
    }
}

1;
