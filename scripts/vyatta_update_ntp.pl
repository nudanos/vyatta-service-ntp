#! /usr/bin/perl

#----- Copyright & License -----
#
# Copyright (C) 2017-2019 AT&T Intellectual Property.
# All Rights Reserved.
#
# Copyright (c) 2014-2017 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: GPL-2.0-only
#
#----- Copyright & License -----

# Filter ntp.conf - remove old servers and add current ones

use strict;
use warnings;
use lib "/opt/vyatta/share/perl5";

use Vyatta::Config;
use Getopt::Long;
use Vyatta::Misc qw(valid_ip_addr valid_ipv6_addr);

my ($rtinstance);
my %SyslogMsgClass = (
    'all'             => 'all',
    'clock'           => 'clock',
    'peer'            => 'peer',
    'system'          => 'sys',
    'synchronization' => 'sync',
);

GetOptions( "rtinstance=s" => \$rtinstance, );

if ( !defined $rtinstance ) {
    $rtinstance = 'default';
}

# Weed vyatta-specific lines from config
while ( my $line = <STDIN> ) {
    if ( $line =~ /^server/ ) {
        last;
    }
    print $line;
}

my $cfg = new Vyatta::Config;
if ( $rtinstance eq 'default' ) {
    $cfg->setLevel("system ntp");
} else {
    $cfg->setLevel("routing routing-instance $rtinstance system ntp");
}

# address family strings
my %afs   = ();
my %proto = ();

foreach my $server ( $cfg->listNodes("server") ) {
    my $af = $cfg->returnValue("server $server address-family");
    if ( defined($af) ) {
        if ( $af eq "ipv6" ) {
            $afs{$server} = "-6 ";
            $proto{'inet6'} = 1;
        } else {
            $afs{$server} = "-4 ";
            $proto{'inet'} = 1;
        }
    } else {
        $afs{$server} = "";
        if ( valid_ip_addr($server) ) {
            $proto{'inet'} = 1;
        } elsif ( valid_ipv6_addr($server) ) {
            $proto{'inet6'} = 1;
        } else {

            # Possibly a DNS name - enable both.
            $proto{'inet'}  = 1;
            $proto{'inet6'} = 1;
        }
    }

    print "server $afs{$server}$server iburst";
    for my $property (qw(noselect preempt prefer)) {
        print " $property" if ( $cfg->exists("server $server $property") );
    }
    print " key ", $cfg->returnValue("server $server keyid")
      if ( $cfg->exists("server $server keyid") );
    print "\n";
}

my $proto_arg = "";
if ( keys %proto ) {
    $proto_arg = "--proto=" . join( ',', ( keys %proto ) );
}

# Source interface
print
`/opt/vyatta/sbin/vyatta_update_ntpsrcIntf.pl --rtinstance=$rtinstance --operation=set $proto_arg`;

print "keys /run/ntp/vrf/$rtinstance/ntp.keys\n";
my @keyids = $cfg->listNodes("keyid");
print "trustedkey ", join( ' ', @keyids ), "\n"
  if ( scalar(@keyids) > 0 );

if ( $cfg->exists("statistics") ) {
    print "\nstatistics loopstats peerstats\n";
    print "statsdir /var/log/ntpsec/\n";
    print "filegen peerstats file peers type day link enable\n";
    print "filegen loopstats file loops type day link enable\n\n";
}

exit 0
  unless $cfg->exists("syslog");

my $logconfig_str = "logconfig =";
foreach my $class ( $cfg->listNodes("syslog") ) {
    next if ( !defined($class) );
    foreach my $type ( $cfg->returnValues("syslog $class type") ) {
        next if ( !defined($type) );
        my $sclass = $SyslogMsgClass{$class};
        if ( substr($logconfig_str, -1) eq "=" ) {
            $logconfig_str = join( "", $logconfig_str, $sclass, $type );
        } else {
            my $ct = join( "", "+", $sclass, $type );
            $logconfig_str = join( " ", $logconfig_str, $ct );
        }
    }
}

if ( substr($logconfig_str, -1) ne "=" ) {
    print "$logconfig_str\n\n";
}

exit 0
