#! /usr/bin/perl -w
###################################################################
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
###################################################################
#    Queries MSA2000 health using the fiber channel management MIB
#    (FCMGMT-MIB). The MIB is available as fa-mib40.mib in the HP
#    SIM MIB kit.
#
#    Tested with:
#    - HP MSA2324i
#    - HP MSA2312i
#    - HP MSA2012i
#    - HP MSA2012fc
#    - HP P2000 G3 MSA (iSCSI & FC)
#
#    For information : dbarbion@gmail.com
###################################################################
#
# Script init
#

use strict;
use Switch ;
use List::Util qw[min max];
use Net::SNMP qw(:snmp);
use FindBin;
use lib "$FindBin::Bin";
use lib "/usr/local/nagios/libexec";
#use utils qw($TIMEOUT %ERRORS &print_revision &support);
use Nagios::Plugin qw(%ERRORS);

use vars qw($PROGNAME);
use Getopt::Long;
use vars qw($opt_h $opt_V $opt_H $opt_C $opt_v $opt_o $opt_c $opt_w $opt_t $opt_p $opt_k $opt_u $opt_l);

$PROGNAME = $0;
sub print_help ();
sub print_usage ();

Getopt::Long::Configure('bundling');
GetOptions
    ("h"   => \$opt_h, "help"         => \$opt_h,
     "u=s" => \$opt_u, "username=s"   => \$opt_u,
     "p=s" => \$opt_p, "password=s"   => \$opt_p,
     "k=s" => \$opt_k, "key=s"        => \$opt_k,
     "V"   => \$opt_V, "version"      => \$opt_V,
     "v=s" => \$opt_v, "snmp=s"       => \$opt_v,
     "C=s" => \$opt_C, "community=s"  => \$opt_C,
     "w=s" => \$opt_w, "warning=s"    => \$opt_w,
     "c=s" => \$opt_c, "critical=s"   => \$opt_c,
     "H=s" => \$opt_H, "hostname=s"   => \$opt_H,
     "l"   => \$opt_l, "list"         => \$opt_l);

if ($opt_V) {
    print_revision($PROGNAME,'$Revision: 1.2');
    exit $ERRORS{'OK'};
}

if ($opt_h) {
    print_help();
    exit $ERRORS{'OK'};
}

$opt_H = shift unless ($opt_H);
(print_usage() && exit $ERRORS{'OK'}) unless ($opt_H);

my $snmp = "1";
if ($opt_v && $opt_v =~ /^[0-9]$/) {
	$snmp = $opt_v;
}

if ($snmp eq "3") {
	if (!$opt_u) {
		print "Option -u (--username) is required for snmpV3\n";
		exit $ERRORS{'OK'};
	}
	if (!$opt_p && !$opt_k) {
		print "Option -k (--key) or -p (--password) is required for snmpV3\n";
		exit $ERRORS{'OK'};
	}elsif ($opt_p && $opt_k) {
		print "Only option -k (--key) or -p (--password) is needed for snmpV3\n";
		exit $ERRORS{'OK'};
	}
}

($opt_C) || ($opt_C = shift) || ($opt_C = "public");

my $DS_type = "GAUGE";
($opt_t) || ($opt_t = shift) || ($opt_t = "GAUGE");
$DS_type = $1 if ($opt_t =~ /(GAUGE)/ || $opt_t =~ /(COUNTER)/);


my $name = $0;
$name =~ s/\.pl.*//g;
my $day = 0;

#===  create a SNMP session ====

my ($session, $error);
if ($snmp eq "1" || $snmp eq "2") {
	($session, $error) = Net::SNMP->session(-hostname => $opt_H, -community => $opt_C, -version => $snmp);
}elsif ($opt_k) {
	($session, $error) = Net::SNMP->session(-hostname => $opt_H, -version => $snmp, -username => $opt_u, -authkey => $opt_k);
}elsif ($opt_p) {
	($session, $error) = Net::SNMP->session(-hostname => $opt_H, -version => $snmp,  -username => $opt_u, -authpassword => $opt_p);
}
# check that session opened
if (!defined($session)) {
    print("UNKNOWN: SNMP Session : $error\n");
    exit $ERRORS{'UNKNOWN'};
}


# Here we go !
my $result ;
my $label ;
my $oid ;
my $unit = "";
my $return_result ;
my $return_code = 0 ;
my $output ;
my $total_connection = 0;
# parse sysDescr
my $sysdescr = $session->get_request(-varbindlist => [".1.3.6.1.2.1.1.1.0"]) ;
if (!defined($sysdescr)) {
    print("UNKNOWN: SNMP get_request : ".$session->error()."\n");
    exit $ERRORS{'UNKNOWN'};
}
my $outlabel = $sysdescr->{".1.3.6.1.2.1.1.1.0"}.": " ;

# useful sensors within FCMGMT-MIB::connUnitSensorTable
my %msa_sensors_oids = (
                        ".1.3.6.1.3.94.1.8.1.1" => "Sensor unitid",
                        ".1.3.6.1.3.94.1.8.1.2" => "Sensor index",
                        ".1.3.6.1.3.94.1.8.1.3" => "Sensor name",
                        ".1.3.6.1.3.94.1.8.1.4" => "Sensor status",
                        ".1.3.6.1.3.94.1.8.1.5" => "Sensor info",
                        ".1.3.6.1.3.94.1.8.1.6" => "Sensor message",
                        ".1.3.6.1.3.94.1.8.1.7" => "Sensor type",  
                        ".1.3.6.1.3.94.1.8.1.8" => "Sensor characteristic"
                        ) ;
my %sensor_data_table = ("SENSOR_UNITID"          => ".1.3.6.1.3.94.1.8.1.1",
                         "SENSOR_INDEX"           => ".1.3.6.1.3.94.1.8.1.2",
                         "SENSOR_NAME"            => ".1.3.6.1.3.94.1.8.1.3",
                         "SENSOR_STATUS"          => ".1.3.6.1.3.94.1.8.1.4",
                         "SENSOR_INFO"            => ".1.3.6.1.3.94.1.8.1.5",
                         "SENSOR_MESSAGE"         => ".1.3.6.1.3.94.1.8.1.6",
                         "SENSOR_TYPE"            => ".1.3.6.1.3.94.1.8.1.7",
                         "SENSOR_CHARACTERISTIC"  => ".1.3.6.1.3.94.1.8.1.8",) ;

# all sensors types
my @msa_sensors_type = ("undefined",
                        "unknown",
                        "other",
                        "battery",
                        "fan",
                        "power-supply",
                        "transmitter",
                        "enclosure",
                        "board",
                        "receiver") ;
# all sensors status
my @msa_sensors_status = ("undefined",
                          "unknown",
                          "other",
                          "ok",
                          "warning",
                          "failed") ;

# all sensors characteristics
my @msa_sensors_characteristic = ("undefined",
                                  "unknown",
                                  "other",
                                  "temperature",
                                  "pressure",
                                  "emf",
                                  "currentValue",
                                  "airflow",
                                  "frequency",
                                  "power",
                                  "door"
                                 ) ;

# get the sensor table
# .1.3.6.1.3.94.1.8 is FCMGMT-MIB::connUnitSensorTable
if ($snmp == 1) {
	$result = $session->get_table(-baseoid => ".1.3.6.1.3.94.1.8") ;
}else {
	$result = $session->get_table(-baseoid => ".1.3.6.1.3.94.1.8", -maxrepetitions => 10) ;
}
if (!defined($result)) {
    print("UNKNOWN: SNMP get_table : ".$session->error()."\n");
    exit $ERRORS{'UNKNOWN'};
}
my %msa_sensors_values = %{$result} ;

my $sensor_id ;
my $key ;
my $value ;
my @msa_sensors ;
my $sensor ;
# create the sensor data table
foreach (keys %msa_sensors_values) {
    $value = $key = $sensor_id = $_ ;
    $sensor_id =~ s/.*\.([0-9]+)$/$1/;
    $key =~ s/(\.[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*).*/$1/ ;
    $msa_sensors[$sensor_id]{$key} = $msa_sensors_values{$value};
}

# When user whan to list probes
if ($opt_l) {
	print "List of probes:\n" ;
}
# parse the table to get the worse status and append it to the output string.
my $worse_status = 0;
foreach $sensor (@msa_sensors) {
    if (defined($sensor)) {
        my %sensor_data = %{$sensor} ;
        $worse_status = max($worse_status, $sensor_data{$sensor_data_table{"SENSOR_STATUS"}}) ;
           
        # a problem is found
        if ($sensor_data{$sensor_data_table{"SENSOR_STATUS"}} > 3) {
            $outlabel.=$sensor_data{$sensor_data_table{"SENSOR_MESSAGE"}} ;
            $outlabel.=" [".$msa_sensors_type[$sensor_data{$sensor_data_table{"SENSOR_TYPE"}}]."]. " ;
        }
        
        # if list option enabled, list sensor data
        if ($opt_l) {
			print $sensor_data{$sensor_data_table{"SENSOR_NAME"}};
			print " (type: ".$msa_sensors_characteristic[$sensor_data{$sensor_data_table{"SENSOR_CHARACTERISTIC"}}].")";
			print " has status ".$msa_sensors_status[$sensor_data{$sensor_data_table{"SENSOR_STATUS"}}] ;
			print " with message: '".$sensor_data{$sensor_data_table{"SENSOR_MESSAGE"}}."'" ;
			print "\n" ;
		}
    }
}

# Check overall status (FCMGMT-MIB::connUnitStatus). This should return a
# warning if any component is unhealthy. This is a column of the connUnitTable,
# and the MSA only returns one row - we're looking for the first row.
my $connUnitStatusOid = '.1.3.6.1.3.94.1.6.1.6';
$result = $session->get_next_request(-varbindlist => [$connUnitStatusOid]);
if (!defined($result)) {
    print("UNKNOWN: SNMP get_next_request $connUnitStatusOid : "
        . $session->error() . "\n");
    exit $ERRORS{'UNKNOWN'};
}
if (length(keys(%$result)) != 1) {
    print("UNKNOWN: Expected 1 connUnitStatus result, got "
        . length(keys(%$result)) . "\n");
    exit $ERRORS{'UNKNOWN'};
}
foreach my $val (values(%$result)) {
    $worse_status = max($worse_status, $val);
    if ($val > 3) {
        $outlabel .= 'Overall unit status ';
    }
    if ($opt_l) {
        print "connUnitStatus has status " . $msa_sensors_status[$val] . "\n";
    }
    last;
}

# get the return_code
switch ($worse_status) {
    case 0 { $return_code = -1 ;}
    case 1 { $return_code = -1 ;}
    case 2 { $return_code = -1 ;}
    case 3 { $return_code = 0 ;}
    case 4 { $return_code = 1 ;}
    case 5 { $return_code = 2 ;}
    else   { $return_code = -1 }
}

################################################################################
switch ($return_code) {
    case 0 { $outlabel.="OK"; }
    case 1 { $outlabel.="WARNING"; }
    case 2 { $outlabel.="CRITICAL"; }
    else   { $outlabel.="UNKOWN"; }
}
print $outlabel."\n" ;
exit($return_code) ;

sub print_usage () {
    print "Usage:";
    print "$PROGNAME\n";
    print "   -H (--hostname)   Hostname to query - (required)\n";
    print "   -C (--community)  SNMP read community (defaults to public,\n";
    print "                     used with SNMP v1 and v2c\n";
    print "   -v (--snmp_version)  1 for SNMP v1 (default)\n";
    print "                        2 for SNMP v2c\n";
    print "   -k (--key)        snmp V3 key\n";
    print "   -p (--password)   snmp V3 password\n";
    print "   -u (--username)   snmp v3 username \n";
    print "   -V (--version)    Plugin version\n";
    print "   -h (--help)       usage help\n\n" ;
    print "   -l (--list)       list probes\n";
}

sub print_help () {
    print_usage();
    print "\n";
}
