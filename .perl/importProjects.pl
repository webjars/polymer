#!/usr/bin/perl

use lib (".perl");

use strict;

use Getopt::Long;

use Template;

use Webjarfier::RepoConfig;

my $fetch_tags;
my $skip_projects;

GetOptions ("fetch-tags"  => \$fetch_tags,
            "skip-projects" => \$skip_projects)   # flag
  or die("Error in command line arguments\n");


my $repo = new Webjarfier::RepoConfig($fetch_tags);

$repo->{skipProjects} = $skip_projects;

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
