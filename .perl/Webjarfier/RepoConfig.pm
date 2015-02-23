package Webjarfier::RepoConfig;

use strict;

use Cwd;

use Log::Log4perl;

use Git::Repository;

use utf8;

use JSON;

my $conf = q(
    log4perl.category.webjars.importer          = INFO, Logfile, Screen

    log4perl.appender.Logfile          = Log::Log4perl::Appender::File
    log4perl.appender.Logfile.filename = importer.log
    log4perl.appender.Logfile.layout   = Log::Log4perl::Layout::PatternLayout
    log4perl.appender.Logfile.layout.ConversionPattern = [%r] %F %L %m%n


    log4perl.appender.Screen         = Log::Log4perl::Appender::Screen
    log4perl.appender.Screen.stderr  = 0
    log4perl.appender.Screen.layout = Log::Log4perl::Layout::SimpleLayout
  );

# ... passed as a reference to init()
Log::Log4perl::init( \$conf );

our $logger = Log::Log4perl->get_logger('webjars.importer');


our $GIT_URL_FORMAT = 'git@github.com:%s/%s.git';


my $pinfos = {
  marked => {
     groupId => 'org.webjars',
     version => '0.3.2'
  },
  highlightjs => {
     groupId => 'org.webjars',
     version => '8.4'
  },
  jquery2 => {
   groupId => 'org.webjars',
   artifactId => 'jquery',
   version => '2.1.3'
  },
  jquery => {
   groupId => 'org.webjars',
   version => '2.1.3'
  },
  'core-field' => {
    artifactId => 'core-label'
  },
  'polymer-ajax' => {
    artifactId => 'core-ajax'
  },
  'polymer-jsonp' => {
    artifactId => 'core-shared-lib'
  }
};

sub new {
  my $class = shift;

  my $this = shift;

  $this->{home} = getcwd();

  $this->{upstreams} = $this->{home} . "/upstreams";

  bless $this, $class;

  $this->_initialize();

  return $this;
}

sub _initialize {
  my $this = shift;

  mkdir $this->{upstreams} unless -d $this->{upstreams};
  die $this->{upstreams} . " should be a directory" unless -d $this->{upstreams};

  $this->cloneOrUpdate("https://github.com/Polymer/tools", "tools");

  $this->{groups}->{polymer} = $this->parseJson('tools/repo-configs/polymer.json');
  $this->{groups}->{core} = $this->parseJson('tools/repo-configs/core.json');
  $this->{groups}->{paper} = $this->parseJson('tools/repo-configs/paper.json');
  $this->{groups}->{labs} = $this->parseJson('tools/repo-configs/labs.json');
  $this->{groups}->{misc} = $this->parseJson('tools/repo-configs/misc.json');

  $this->{groups}->{deprecated} = $this->parseJson('tools/repo-configs/deprecated.json');

  $this->{modules} = {};


}

sub importProjects {
  my $this = shift;

  #$this->dumpJson($this->{polymer});

  $this->importGroups('polymer');
  $this->importGroups('core');
  $this->importGroups('paper');
  $this->importGroups('labs');
  $this->importGroups('misc');
  $this->importGroups('deprecated') if $this->{'with-deprecated'};

  chdir $this->{home};

  return $this->{modules}->{polymer}->{version}
}

sub importGroups {
  my $this = shift;
  my $groupsName = shift;

  my @groups = @{$this->{groups}->{$groupsName}};

  $logger->info("Importing $groupsName " . ($#groups+1) . " group(s).");

  for my $group (@groups){
    $this->importGroup($group);
  }
}

sub cloneOrUpdate {
  my $this = shift;
  my $url = shift;
  my $dir = shift;

  my $repo = $this->{upstreams} . "/" . $dir;

  if(-d $repo){
    $logger->info("Updating polymer tools");
  }else{
    $logger->info("Cloning polymer tools");
    Git::Repository->run( clone => $url, $repo );
  }

}

sub importGroup {
  my $this = shift;
  my $group = shift;

  return unless $group->{dir} ne "projects" || $this->{'with-projects'};

  $logger->info("Importing group " . $group->{dir} );

  $group->{_home} = $this->{upstreams} . '/' . $group->{dir};

  mkdir $group->{_home} unless -d $group->{_home};

  chdir $group->{_home};

  for my $repo ( @{$group->{repos}}){
    my $git;
    my $module;
    if($repo =~ m/([^:]+)::([^:]+)/ ){
       $repo = $1;
       $module = $2;
    }else{
       $module = $repo;
    }


    if(-d $module){
      $logger->debug("$repo already cloned in $module");
      $git = Git::Repository->new( work_tree => $module );
      $git->run(fetch => '--tags') if $this->{'fetch-tags'};
    }else{
      my $url = sprintf($GIT_URL_FORMAT, $group->{org}, $repo );
      $logger->info("Cloning $repo from $url to $module");
      Git::Repository->run( clone => $url, $module );
      $git = Git::Repository->new( work_tree => $module );
    }

    my ($version, $lastRelease, $prefix) = &lastRelease($git);

    my $moduleInfo = {
      version=> $version,
      prefix => $prefix,
      artifactId => $module,
      groupId => 'org.webjars',
      org => $group->{org},
      dependencies => []
    };

    $moduleInfo->{bower_module} = 'firebase-bower' if $module eq 'firebase';

    if('master' eq $lastRelease){
      $logger->warn("No release for $module");
    } else {
      my $currentBranch = $git->run('rev-parse' => '--abbrev-ref', 'HEAD');
      my $lastRelease_branch = 'branch_' . $lastRelease;
      if($lastRelease_branch eq $currentBranch){
      }else{
        if($git->run("show-ref" => 'refs/heads/' . $lastRelease_branch)){
          $git->run(checkout => $lastRelease_branch);
        }else{
          $git->run(checkout => '-b', $lastRelease_branch, $lastRelease);
        }
      }
    }

    my $bower = $this->bower($group, $module, $lastRelease);

    $moduleInfo->{bower} = $bower;

    $this->setDependencies($moduleInfo, $bower);

    $this->{modules}->{$module} = $moduleInfo;

  }
}


my $dependencies_hacks = {
   'core-icon' => {"core-icons"=>1},
   'core-iconset' => {"core-icon" => 1},
   'polymer' => {"core-component-page" => 1},
   'paper-docs' => {"paper-doc-viewer" => 1},
   'core-label' => {'paper-checkbox' => 1 }
};

sub setDependencies {
  my $this = shift;
  my $moduleInfo = shift;
  my $bower = shift;


  foreach my $dep (sort keys %{$bower->{dependencies}}) {
      my $value = $bower->{dependencies}->{$dep};
      if($value =~ m!([^/]+)/([^#]+)#[\^~](.*)!){
      my $org = $1;
      my $artifactId = $2;
      my $version = '['.$3.',]';

      next if $dependencies_hacks->{$moduleInfo->{artifactId}}->{$artifactId};

      my $groupId = 'org.webjars';



      #$groupId .= '.polymers' if "Polymer" eq $org;
      #$groupId .= '.polymers' if "PolymerLabs" eq $org;

      $artifactId = $pinfos->{$artifactId}->{artifactId} if $pinfos->{$artifactId}->{artifactId};
      $groupId = $pinfos->{$artifactId}->{groupId} if $pinfos->{$artifactId}->{groupId};
      $version = $pinfos->{$artifactId}->{version} if $pinfos->{$artifactId}->{version};
      $version = $this->{modules}->{polymer}->{version} if $artifactId =~ m/^core\-.*$/;

      $version = $this->{modules}->{polymer}->{version} if $artifactId =~ m/^paper\-.*$/;
      $version = $this->{modules}->{polymer}->{version} if $artifactId eq "polymer";

      push @{$moduleInfo->{dependencies}}, {
       groupId => $groupId,
       artifactId => $artifactId,
       version => $version
      };
    }
  }

}

sub bower {
  my $this = shift;
  my $group = shift;
  my $module = shift;
  my $version = shift;

  my $bower = $this->parseJson($group->{dir} . '/' . $module . "/bower.json");
  return $bower if $bower;

  $logger->warn("No bower file for $module");

  my $cwd = getcwd();

  $logger->debug("Parsing html file in $module ($cwd)" );

  $bower = {
    name => $module,
    private => 'true',
    dependencies => {},
    version => $version
  };

  my $dhacks = {};

  my $filePattern = $module . "/*.html";

  chdir $module;

  my @htmls = <"*.html">;
  foreach my $html (@htmls){
    open my $fh, "<", $html;
    while(<$fh>){
      chomp;
      if(m!<link rel="import" href="\.\./([^/]+)/.*!){
        my $d = $1;
        $logger->debug( $d ) unless $dhacks->{$d};
        $bower->{dependencies}->{$d} = $group->{org} . '/' . $module unless $dhacks->{$d};
        $dhacks->{$d} = 1;
      }
    }
    close $fh;
  }
  chdir $cwd;
  return $bower;
}


#
# Will return the last release tag or 'master' if none found.
#      First attempt with regexp \d+\.\d+(\.\d{1,4}
#      Second attempt with regexp ^v?\d+\.\d+(\.\d{1,4}
#
sub lastRelease {
  my $git = shift;
  my @tags = reverse $git->run(tag => "--sort",'version:refname');
  foreach (@tags){
     return ($_, $_) if m!^\d+\.\d+(\.\d{1,4})?$!
  }
  foreach (@tags){
    return ($2, $_, $1) if m!^([a-zA-Z]+)(\d+\.\d+(\.\d{1,4})?)$!
  }
  return ('master', 'master');
}

sub dumpJson {
  my $this = shift;
  my $json = shift;
  my $indent = shift || 0;

  if(ref($json) eq "ARRAY"){
    print " " x $indent, "[\n";
    foreach (@$json){
      $this->dumpJson($_, $indent+1);
    }
    print " " x $indent, "]\n";
  }elsif(ref($json) eq "HASH"){
    print " " x $indent, "{\n";
    while (my ($key,$value) = each $json) {
     print " " x $indent, $key, " =>";
     $this->dumpJson($value, $indent+1);
    }
    print " " x $indent, "}\n";
  }elsif(ref($json) eq ""){
     print " " x $indent, $json, "\n";
  }else{
    print "WTF: ", ref($json), ': ', $json, "\n";
  }
}

sub parseJson {
  my $this = shift;
  my $relative = shift;
  my $path = $this->{upstreams} . '/' . $relative;
  binmode STDOUT, ":utf8";

  return undef unless -e $path;

  if(-e $path){
    local $/; #Enable 'slurp' mode
    open my $fh, "<", $path;
    my $json = <$fh>;
    close $fh;

    $logger->debug('Parsed ' . $path);

    return decode_json($json);
  }
}

1;
