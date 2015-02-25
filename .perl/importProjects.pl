#!/usr/bin/perl

use lib (".perl");

use strict;

use Getopt::Long;

use Template;

use Webjarfier::RepoConfig;

my $options = {};


GetOptions ($options, 'fetch-tags', 'with-projects', 'with-deprecated', 'force-parse-html')
  or die("Error in command line arguments\n");


my $repo = new Webjarfier::RepoConfig($options);

my $polymers_version = $repo->importProjects();
#$polymers_version .= "-SNAPSHOT";


my $rootPomTemplate = Template->new;
my $modules = $repo->{modules};
my @modules = sort keys %$modules;


$rootPomTemplate->process('.perl/Webjarfier/root-pom.xml',
                          { version => $polymers_version ,
                             modules => \@modules },
                          "pom.xml")
    || die $rootPomTemplate->error;
foreach my $module (@modules){
  mkdir $module;
  open WEBJAR, ">" . $module . "/webjar";
  print WEBJAR "maven profile activation";
  close WEBJAR;
  $rootPomTemplate->process('.perl/Webjarfier/webjar-pom.xml',
                          {
                           polymer_version => $polymers_version,
                          module => $modules->{$module} },
                          "$module/pom.xml")
    || die $rootPomTemplate->error;
}
