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
#    For information : david.barbion@adeoservices.com
####################################################################
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
use Data::Dumper ;

use vars qw($PROGNAME);
use Getopt::Long;
use vars qw($opt_h $opt_V $opt_H $opt_C $opt_v $opt_o $opt_c $opt_w $opt_t $opt_p $opt_k $opt_u $opt_d $opt_i $opt_P);
use constant true  => "1" ;
use constant false => "0" ;
$PROGNAME = $0;
my $version = 1;
my $release = 0;
sub print_help ();
sub print_usage ();
sub verbose ;
sub get_nexus_table ;
sub get_nexus_entries ;
sub get_nexus_component_location ;
sub evaluate_sensor ;
my $opt_d = 0 ;
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
     "d=s" => \$opt_d, "debug=s"      => \$opt_d,
     "i"   => \$opt_i, "sysdescr"     => \$opt_i,
     "P=s" => \$opt_P);

if ($opt_V) {
    print($PROGNAME.': $Revision: '.$version.'.'.$release."\n");
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

my $name = $0;
$name =~ s/\.pl.*//g;

#===  create a SNMP session ====

my ($session, $error);
if ($snmp eq "1" || $snmp eq "2") {
	($session, $error) = Net::SNMP->session(-hostname => $opt_H, -community => $opt_C, -version => $snmp, -maxmsgsize => "5000");
}elsif ($opt_k) {
	($session, $error) = Net::SNMP->session(-hostname => $opt_H, -version => $snmp, -username => $opt_u, -authkey => $opt_k, -maxmsgsize => "5000");
}elsif ($opt_p) {
	($session, $error) = Net::SNMP->session(-hostname => $opt_H, -version => $snmp,  -username => $opt_u, -authpassword => $opt_p, -maxmsgsize => "5000");
}
# check that session opened
if (!defined($session)) {
    print("UNKNOWN: SNMP Session : $error\n");
    exit $ERRORS{'UNKNOWN'};
}


# Here we go !
my $loglevel = $opt_d ;
my %perfparse ;
# parse sysDescr
my $outlabel_oid;
if ($opt_i) {
	# sysdescr
	$outlabel_oid = ".1.3.6.1.2.1.1.1.0" ;
}else {
	# sysname
	$outlabel_oid = ".1.3.6.1.2.1.1.5.0" ;
}
verbose("get sysdescr ($outlabel_oid)", "5") ;
my $sysdescr = $session->get_request(-varbindlist => [$outlabel_oid]) ;
if (!defined($sysdescr)) {
	print("UNKNOWN: SNMP get_request : ".$session->error()."\n");
	exit $ERRORS{'UNKNOWN'};
}
verbose(" sysdescr is ".$sysdescr->{$outlabel_oid}, "5") ;
my $outlabel = $sysdescr->{$outlabel_oid}.": " ;
my @nagios_return_code = ("OK", "WARNING", "CRITICAL", "UNKNOWN") ;

# define some useful constants
####################
use constant netapp_nfsops => ".1.3.6.1.4.1.789.1.2.2.27.0" ;


##################### RETRIEVE DATA #######################
###### get the cpmCPU table
my $label;
my $netapp_nfsops=0 ;
my $mean_netapp_nfsops ;
my $current_netapp_nfsops ;
my $return_code=0;
my $date_of_measure = time() ;
my $cache_file = "/var/lib/centreon/centplugins/netapp_ops.$opt_H" ;
my $interval_time ;

# get total number of nfsops 
verbose("get netapp nfs ops", "5") ;
my $netapp_current_nfsops = $session->get_request(-varbindlist => [&netapp_nfsops]) ;
verbose("nfsops=".$netapp_current_nfsops->{&netapp_nfsops}, 10) ;
$current_netapp_nfsops=$netapp_current_nfsops->{&netapp_nfsops} ;

# user defined cache path
if (defined($opt_P)) {
   $cache_file = $opt_P."/netapp_ops.$opt_H" ;
}

# retrieve old data store in the cache file
my %history = get_history($cache_file) ;
if (!defined($history{'time'})) {
   verbose("First time running", 5) ;
   $label = "Buffer in creation" ;
   $return_code = 3 ;
}else {
   $interval_time = $date_of_measure - $history{'time'} ;
   $netapp_nfsops = $current_netapp_nfsops - $history{'nfsops'} ; 

   $mean_netapp_nfsops = $netapp_nfsops / $interval_time ;

   $return_code = 0 ;
   if (defined($opt_w) && $mean_netapp_nfsops < $opt_w) {
      if (defined($opt_c) && $mean_netapp_nfsops < $opt_c) {
         $return_code = 2 ;
      }else{
         $return_code = 1 ;  
      }
   }
   $label .= "nfsops=$mean_netapp_nfsops (${interval_time}s mean)";
   $perfparse{'nfsops'} = $mean_netapp_nfsops;
}
$history{'time'} = $date_of_measure ;
$history{'nfsops'} = $current_netapp_nfsops ;
save_history($cache_file, %history) ;
###########################################################################################

print $outlabel.$nagios_return_code[$return_code]." $label |" ;
print " nfsops=".$perfparse{'nfsops'}."ops;" ;
print "\n" ;
exit($return_code) ;

sub get_history {
   my $cachefile = $_[0] ;
   my $histvalue ;
   my $time ;
   my %history ;
   $history{'time'} = undef ;
   my $row ;
   if (-e $cachefile) {
      open(FILE, "<$cachefile") ;
      while($row = <FILE>) {
         if ($row =~ /^time (.*)/) {
             verbose("found time from history: $1", 10) ;
             $history{'time'} = $1 ;
         }
         if ($row =~ /^nfsops (.*)/) {
             verbose("found last value from history: $1", 10) ;
             $history{'nfsops'} = $1 ;
         }
      }
      close(FILE) ;
   }
   return(%history) ;
}

sub save_history {
   my $cachefile = $_[0] ;
   my $history = $_[1] ;
   my $time ;

   open(FILE, ">$cachefile") ;
   print FILE "time ".$history{'time'}."\n" ;
   print FILE "nfsops ".$history{'nfsops'}."\n" ;
   close(FILE) ;
}

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
    print "   -i (--sysdescr)   use sysdescr instead of sysname for label display\n";
    print "   -w (--warning)    minimal threshold for warning\n" ;
    print "   -c (--critical)   minimal threshold for critical\n" ;
    print "\n" ;
    print "   -d (--debug)      debug level (1 -> 15)\n" ;
}

sub print_help () {
    print "##############################################\n";
    print "#                ADEO Services               #\n";
    print "##############################################\n";
    print_usage();
    print "\n";
}

sub verbose {
    my $message = $_[0];
    my $messagelevel = $_[1] ;


    if ($messagelevel <= $loglevel) {
        print "$message\n" ;
	}
}

sub get_table {
    my $baseoid = $_[0] ;    
    my $is_indexed = $_[1] ;
    my $key;
    my $value;
    my $result ;

    verbose("get table for oid $baseoid", "10") ;
    if ($snmp == 1) {
    	$result = $session->get_table(-baseoid => $baseoid) ;
    }else {
    	$result = $session->get_table(-baseoid => $baseoid, -maxrepetitions => 20) ;
    }
    if (!defined($result)) {
        print("UNKNOWN: SNMP get_table : ".$session->error()."\n");
        exit $ERRORS{'UNKNOWN'};
    }
    my %nexus_values = %{$result} ;
    my $id;
    my $index;
    my %nexus_return;
    while(($key,$value) = each(%nexus_values)) {
        $index = $id = $key ;
		if ($is_indexed) {
            $id =~ s/.*\.([0-9]+)\.[0-9]*$/$1/;
            $key =~ s/(.*)\.[0-9]*\.[0-9]*/$1/ ;
            $index =~ s/.*\.([0-9]+)$/$1/ ;
    	    verbose("key=$key, id=$id, index=$index, value=$value", "15") ;
            $nexus_return{$id}{$key}{$index} = $value;
            $nexus_return{$id}{"id"}{$index} = $id ;
		}else {
            $id =~ s/.*\.([0-9]+)$/$1/;
            $key =~ s/(.*)\.[0-9]*/$1/ ;
    	    verbose("key=$key, id=$id, value=$value", "15") ;
            $nexus_return{$id}{$key} = $value;
            $nexus_return{$id}{"id"} = $id ;
		}
    }
    return(%nexus_return) ;
}

