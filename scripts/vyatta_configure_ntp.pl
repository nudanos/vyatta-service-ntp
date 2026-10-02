#! /usr/bin/perl

#----- Copyright & License -----
#
# Copyright (C) 2017-2019 AT&T Intellectual Property.
# All Rights Reserved.
#
# Copyright (c) 2016-2017 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: GPL-2.0-only
#
#----- Copyright & License -----

use strict;
use warnings;
use lib "/opt/vyatta/share/perl5";

use Vyatta::Config;
use Vyatta::Configd;
use Getopt::Long;
use Switch;

use File::Copy;
use File::Path qw(make_path remove_tree);

my ( $operation, $rtinstance );
GetOptions(
    "operation=s"  => \$operation,
    "rtinstance=s" => \$rtinstance,
);

if ( !defined $operation ) {
    exit 1;
}
if ( !defined $rtinstance ) {
    $rtinstance = 'default';
}

sub _setup_config () {
    my $ntp_path = "/run/ntp/vrf/$rtinstance";
    make_path( "$ntp_path", { mode => 644 } );

    # Keys
    `touch $ntp_path/ntp.keys`;
    chmod 600, "$ntp_path/ntp.keys";
    system("/opt/vyatta/sbin/vyatta_update_ntpkeys --rtinstance=$rtinstance >> $ntp_path/ntp.keys");

    system("/opt/vyatta/sbin/vyatta_update_ntp.pl --rtinstance=$rtinstance < /opt/vyatta/etc/ntp.conf > $ntp_path/ntp.conf");

    # For backward compat
    if ( $rtinstance eq "default" ) {
        unlink "/etc/ntpsec/ntp.conf";
        symlink( "$ntp_path/ntp.conf", "/etc/ntpsec/ntp.conf" );
    }
}

sub _start_ntp() {
    system('vmware-toolbox-cmd timesync disable > /dev/null 2>&1')
      if -e '/usr/bin/vmware-toolbox-cmd';

    if ( $rtinstance eq "default" ) {
        system("systemctl start ntpsec");
    } else {
        open( my $f, '>', "/run/ntp/vrf/$rtinstance/$rtinstance.env" )
          or die("$0: Could not open systemd env for writing $!\n");
        print $f "NTPD_CONF_FILE=-c /run/ntp/vrf/$rtinstance/ntp.conf\n";
        print $f "VRFName=$rtinstance\n";
        close($f);
        system("systemctl start ntpd\@$rtinstance.service");
    }
}

sub _stop_ntp {
    my ($terminal) = @_;
    my $status;
    if ( $rtinstance eq "default" ) {
        $status = `systemctl is-active ntpsec.service`;
        if ( ( !defined $status ) || ( $status =~ /^inactive/ ) ) {
            return;
        }
        system("systemctl stop ntpsec");
    } else {
        $status = `systemctl is-active ntpd\@$rtinstance.service`;
        if ( ( !defined $status ) || ( $status =~ /^inactive/ ) ) {
            return;
        }
        system("systemctl stop ntpd\@$rtinstance.service");
    }
    if ( $terminal == 1 ) {
        remove_tree("/run/ntp");
        unlink "/etc/ntpsec/ntp.conf";
    }

    system('vmware-toolbox-cmd timesync enable > /dev/null 2>&1')
      if -e '/usr/bin/vmware-toolbox-cmd';
}

# This function validates that only one ntp server
# has been configured on the system
sub _exclusive_ntp() {
    my $db      = $Vyatta::Configd::Client::AUTO;
    my $cfg     = Vyatta::Configd::Client->new();
    my $got_ntp = 0;
    my $cfg_ntp = "system ntp server";

    my @servers = $cfg->get("$cfg_ntp");
    foreach my $server (@servers) {
        if ( $cfg->node_exists( $db, "$cfg_ntp $server" ) ) {
            $got_ntp = 1;
            last;
        }
    }

    my $cfg_rt = 'routing routing-instance';
    my @rts    = $cfg->get("$cfg_rt");
    foreach my $rt (@rts) {
        my @servers = $cfg->get("$cfg_rt $rt $cfg_ntp");
        foreach my $server (@servers) {
            if ( $cfg->node_exists( $db, "$cfg_rt $rt $cfg_ntp $server" ) ) {
                if ( $got_ntp == 1 ) {
                    die
                      "Error: only one NTP client can be configured at once\n";
                } else {
                    # Checked this VRF, now move to the next one
                    $got_ntp = 1;
                    last;
                }
            }
        }
    }
    return $got_ntp;
}

switch ($operation) {
    my $terminal = 1;

    case 'start' {
        if ( _exclusive_ntp() != 1 ) {
            exit 0;    # Silent exit. Ntp configuartion without servers
                       # is possible. Don't throw any errors.
        }
        _setup_config();
        _start_ntp();
    }
    case 'stop' {
        _stop_ntp($terminal);
    }
    case 'restart' {
        _stop_ntp($terminal);
        if ( _exclusive_ntp() != 1 ) {
            exit 0;
        }
        _setup_config();
        _start_ntp();
    }
    case 'restart_trigger' {
        $terminal = 0;
        _stop_ntp($terminal);
        _start_ntp();
    }
}
