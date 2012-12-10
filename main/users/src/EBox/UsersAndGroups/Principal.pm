#!/usr/bin/perl

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

# Class: EBox::UsersAndGroups::Principal
#
#   Kerberos principal, stored in LDAP
#

use strict;
use warnings;

package EBox::UsersAndGroups::Principal;

use base 'EBox::UsersAndGroups::LdapObject';

sub new
{
    my $class = shift;
    my %opts = @_;
    my $self = $class->SUPER::new(@_);
    bless ($self, $class);
    return $self;
}

1;