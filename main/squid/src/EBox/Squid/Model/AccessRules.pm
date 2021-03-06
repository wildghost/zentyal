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
use strict;
use warnings;

package EBox::Squid::Model::AccessRules;
use base 'EBox::Model::DataTable';


use EBox;
use EBox::Global;
use EBox::Exceptions::Internal;
use EBox::Gettext;
use EBox::Types::Text;
use EBox::Types::Select;
use EBox::Types::Union;
use EBox::Types::Union::Text;
use EBox::Squid::Types::TimePeriod;

use constant MAX_DG_GROUP => 99; # max group number allowed by dansguardian

# Method: _table
#
#
sub _table
{
    my ($self) = @_;

    my @tableHeader = (
        new EBox::Squid::Types::TimePeriod(
                fieldName => 'timePeriod',
                printableName => __('Time period'),
                help => __('Time period when the rule is applied'),
                editable => 1,
        ),
        new EBox::Types::Union(
            fieldName     => 'source',
            printableName => __('Source'),
            filter        => \&_filterSourcePrintableValue,
            subtypes => [
                new EBox::Types::Select(
                    fieldName     => 'object',
                    foreignModel  => $self->modelGetter('objects', 'ObjectTable'),
                    foreignField  => 'name',
                    foreignNextPageField => 'members',
                    printableName => __('Network Object'),
                    unique        => 1,
                    editable      => 1,
                    optional      => 0,
                ),
                new EBox::Types::Select(
                    fieldName     => 'group',
                    printableName => __('Users Group'),

                    populate      => \&populateGroups,
                    unique        => 1,
                    editable      => 1,
                    optional      => 0,
                    disableCache  => 1,
                ),
                new EBox::Types::Union::Text(
                    fieldName => 'any',
                    printableName => __('Any'),
                )
            ]
        ),
        new EBox::Types::Union(
            fieldName     => 'policy',
            printableName => __('Decision'),
            filter        => \&_filterProfilePrintableValue,
            subtypes => [
                new EBox::Types::Union::Text(
                    fieldName => 'allow',
                    printableName => __('Allow All'),
                ),
                new EBox::Types::Union::Text(
                    fieldName => 'deny',
                    printableName => __('Deny All'),
                ),
                new EBox::Types::Select(
                    fieldName => 'profile',
                    printableName => __('Apply Filter Profile'),
                    foreignModel  => $self->modelGetter('squid', 'FilterProfiles'),
                    foreignField  => 'name',
                    editable      => 1,
                )
            ]
        ),
    );

    my $dataTable =
    {
        tableName          => 'AccessRules',
        pageTitle          => __('HTTP Proxy'),
        printableTableName => __('Access Rules'),
        modelDomain        => 'Squid',
        defaultActions     => [ 'add', 'del', 'editField', 'changeView', 'clone', 'move' ],
        tableDescription   => \@tableHeader,
        class              => 'dataTable',
        order              => 1,
        rowUnique          => 1,
        automaticRemove    => 1,
        printableRowName   => __('rule'),
        help               => __('Here you can filter, block or allow access by user group or network object. Rules are only applied during the selected time period.'),
    };
}

sub populateGroups
{
    my $userMod = EBox::Global->modInstance('users');
    return [] unless ($userMod->isEnabled());

    my @groups;
    push (@groups, { value => '__USERS__', printableValue => __('All users') });
    foreach my $group (@{$userMod->groups()}) {
        my $name = $group->name();
        push (@groups, { value => $name, printableValue => $name });
    }
    return \@groups;
}

sub validateTypedRow
{
    my ($self, $action, $params_r, $actual_r) = @_;

    my $squid = $self->parentModule();


    my $sourceType = exists $params_r->{source} ?
                      $params_r->{source}->selectedType():
                      $actual_r->{source}->selectedType();
    if ($squid->transproxy() and ($sourceType eq 'group')) {
        throw EBox::Exceptions::External(__('Source matching by user group is not compatible with transparent proxy mode'));
    }

    # check if it is a incompatible rule
     my $groupRules;
     my $objectProfile;
     if ($sourceType eq 'group') {
         $groupRules = 1;
     } else {
        my $policy = exists $params_r->{policy} ?  $params_r->{policy}->selectedType
                                                 :  $actual_r->{policy}->selectedType();
         if (($policy eq 'allow') or ($policy eq 'profile') ) {
             $objectProfile = 1;
         }
     }

    if ((not $groupRules) and (not $objectProfile)) {
        return;
    }

    my $ownId = $params_r->{id};
    foreach my $id (@{ $self->ids() }) {
        next if ($id eq $ownId);

        my $row = $self->row($id);
        my $source = $row->elementByName('source')->selectedType();
        if ($objectProfile and ($source eq 'group')) {
            throw EBox::Exceptions::External(
              __("You cannot add a 'Allow' or 'Profile' rule for an object or any address if you have group rules")
             );
        } elsif ($groupRules and ($source ne 'group')) {
            if ($row->elementByName('policy')->selectedType() ne 'deny') {
                throw EBox::Exceptions::External(
                 __("You cannot add a group-based rule if you have an 'Allow' or 'Profile' rule for objects or any address")
               );
            }
        }
    }
}

sub rules
{
    my ($self) = @_;

    my $objectMod = $self->global()->modInstance('objects');
    my $userMod = $self->global()->modInstance('users');
    my $usersEnabled = $userMod->isEnabled();

    # we dont use row ids to make rule id shorter bz squid limitations with id length
    my $number = 0;
    my @rules;
    foreach my $id (@{$self->ids()}) {
        my $row = $self->row($id);
        my $source = $row->elementByName('source');

        my $rule = { number => $number};
        if ($source->selectedType() eq 'object') {
            my $object = $source->value();
            $rule->{object} = $object;
            $rule->{members} = $objectMod->objectMembers($object);
            my $addresses = $objectMod->objectAddresses($object);
            # ignore empty objects
            next unless @{$addresses};
            $rule->{addresses} = $addresses;
        } elsif ($source->selectedType() eq 'group') {
            next unless ($usersEnabled);
            my $group = $source->value();
            $rule->{group} = $group;
            my $users;
            if ($group eq '__USERS__') {
                $users = $userMod->users();
            } else {
                $users = $userMod->group($group)->users();
            }

            if (not @{ $users }) {
                # ignore rules for empty groups
                next;
            }
            $rule->{users} = [ (map {
                                      my $name =  $_->name();
                                      lc $name;
                                  } @{$users}) ];
        } elsif ($source->selectedType() eq 'any') {
            $rule->{any} = 1;
        }

        my $policyElement = $row->elementByName('policy');
        my $policyType =  $policyElement->selectedType();
        $rule->{policy} = $policyType;
        if ($policyType eq 'profile') {
            $rule->{profile} = $policyElement->value();
        }

        my $timePeriod = $row->elementByName('timePeriod');
        if (not $timePeriod->isAllTime) {
            if (not $timePeriod->isAllWeek()) {
                $rule->{timeDays} = $timePeriod->weekDays();
            }

            my $hours = $timePeriod->hourlyPeriod();
            if ($hours) {
                $rule->{timeHours} = $hours;
            }
        }

        push (@rules, $rule);
        $number += 1;
    }

    return \@rules;
}


sub squidFilterProfiles
{
    my ($self) = @_;

    my $enabledProfiles = $self->_enabledProfiles();
    my $filterProfiles = $self->parentModule()->model('FilterProfiles');
    my $acls = $filterProfiles->squidAcls($enabledProfiles);
    my $rulesStubs = $filterProfiles->squidRulesStubs($enabledProfiles, sharedAcls => $acls->{shared});
    return {
              acls => $acls->{all},
              rulesStubs => $rulesStubs,
           };
}

sub existsPoliciesForGroup
{
    my ($self, $group) = @_;
    foreach my $id (@{ $self->ids() }) {
        my $row = $self->row($id);
        my $source = $row->elementByName('source');
        next unless $source->selectedType() eq 'group';
        my $userGroup = $source->value();
        if ($group eq $userGroup) {
            return 1;
        }
    }

    return 0;
}

sub delPoliciesForGroup
{
    my ($self, $group) = @_;
    my @ids = @{ $self->ids() };
    foreach my $id (@ids) {
        my $row = $self->row($id);
        my $source = $row->elementByName('source');
        next unless $source->selectedType() eq 'group';
        my $userGroup = $source->printableValue();
        if ($group eq $userGroup) {
            $self->removeRow($id);
        }
    }
}

sub filterProfiles
{
    my ($self) = @_;

    my $filterProfilesModel = $self->parentModule()->model('FilterProfiles');
    my %profileIdByRowId = %{ $filterProfilesModel->idByRowId() };

    my $objectMod = $self->global()->modInstance('objects');
    my $userMod = $self->global()->modInstance('users');

    my @profiles;
    foreach my $id (@{$self->ids()}) {
        my $row = $self->row($id);

        my $profile = {};

        my $policy     = $row->elementByName('policy');
        my $policyType = $policy->selectedType();
        if ($policyType eq 'allow') {
            $profile->{number} = 2;
        } elsif ($policyType eq 'deny') {
            $profile->{number} = 1;
        } elsif ($policyType eq 'profile') {
            my $rowId = $policy->value();
            $profile->{number} = $profileIdByRowId{$rowId};
            $profile->{usesFilter} = $filterProfilesModel->usesFilterById($rowId);
        } else {
            throw EBox::Exceptions::Internal("Unknown policy type: $policyType");
        }
        $profile->{policy} = $policyType;

        my $timePeriod = $row->elementByName('timePeriod');
        unless ($timePeriod->isAllTime()) {
            $profile->{timePeriod} = 1;
            $profile->{begin} = $timePeriod->from();
            $profile->{end} = $timePeriod->to();
            $profile->{days} = $timePeriod->dayNumbers();
        }

        my $source = $row->elementByName('source');
        my $sourceType = $source->selectedType();
        $profile->{source} = $sourceType;
        if ($sourceType eq 'any') {
            $profile->{anyAddress} = 1;
            $profile->{address} = '0.0.0.0/0.0.0.0';
            push @profiles, $profile;
        } elsif ($sourceType eq 'object') {
            my $obj       = $source->value();
            my @addresses = @{ $objectMod->objectAddresses($obj, mask => 1) };
            foreach my $cidrAddress (@addresses) {
                # put a pseudo-profile for each address in the object
                my ($addr, $netmask) = ($cidrAddress->[0], EBox::NetWrappers::mask_from_bits($cidrAddress->[1]));
                my %profileCopy = %{$profile};
                $profileCopy{address} = "$addr/$netmask";
                push @profiles, \%profileCopy;
            }
        } elsif ($sourceType eq 'group') {
            my $group = $source->value();
            $profile->{group} = $group;
            my $users;
            if ($group eq '__USERS__') {
                $users = $userMod->users();
            } else {
                $users = $userMod->group($group)->users();
            }
            my @users = @{ $users };
            @users or next;
            $profile->{users} = [ map { $_->name() }  @users ];
            push @profiles, $profile;
        } else {
            throw EBox::Exceptions::Internal("Unknow source type: $sourceType");
        }
    }

    return \@profiles;
}

sub rulesUseAuth
{
    my ($self) = @_;

    foreach my $id (@{$self->ids()}) {
        my $row = $self->row($id);
        my $source = $row->elementByName('source');
        if ($source->selectedType() eq 'group') {
            return 1;
        }
    }

    return 0;
}

sub rulesUseFilter
{
    my ($self) = @_;
    my $profiles = $self->_enabledProfiles();
    my $filterProfiles = $self->parentModule()->model('FilterProfiles');
    return $filterProfiles->usesFilter($profiles);
}

sub _enabledProfiles
{
    my ($self) = @_;
    my %profiles;
    foreach my $id (@{ $self->ids()  }) {
        my $row = $self->row($id);
        my $policy = $row->elementByName('policy');
        if ($policy->selectedType eq 'profile') {
            $profiles{$policy->value()} = 1;
        }
    }
    return [keys %profiles];
}

sub _filterSourcePrintableValue
{
    my ($type) = @_;

    my $selected = $type->selectedType();
    my $value = $type->printableValue();

    if ($selected eq 'object') {
        return __x('Object: {o}', o => $value);
    } elsif ($selected eq 'group') {
        return __x('Group: {g}', g => $value);
    } else {
        return $value;
    }
}

sub _filterProfilePrintableValue
{
    my ($type) = @_;

    if ($type->selectedType() eq 'profile') {
        return __x("Apply '{p}' profile", p => $type->printableValue());
    } else {
        return $type->printableValue();
    }
}

1;
