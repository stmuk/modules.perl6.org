package P6Project::Info;

use strict;
use warnings;
use 5.010;

use Mojo::JSON qw/decode_json/;
use File::Slurp;
use P6Project::Hosts::Github;
## TODO: add Gitorious support.

sub new {
    my ($class, %opts) = @_;
    my $self  = \%opts;
    return bless $self, $class;
}

sub p6p {
    my ($self) = @_;
    return $self->{p6p};
}

sub get_projects {
    my ($self, $list_url) = @_;
    my $ua = $self->p6p->ua;
    my $stats = $self->p6p->stats;
    my $projects = {};
    my $contents = eval { read_file('META.list.local') } || $ua->get($list_url)->res->body;
    my $hosts = {
        'github' => P6Project::Hosts::Github->new(p6p=>$self->p6p)
    };
    my $total = scalar (split "\n", $contents);
    print "Total: $total\n";
    my $cnt = 0;
    for my $proj (split "\n", $contents) {
        $cnt++;
        last if $self->{limit} and $self->{limit} < $cnt;
        print "$cnt/$total $proj\n";
        my $json = $ua->get($proj)->res->json;
        if (!$json) {
            $stats->error("Invalid json found at: $proj");
            next;
        }
        my $name = $json->{'name'};
        unless (defined $name) {
            warn "$proj has no name, skipping!\n";
            next;
        }

        my $url = $json->{'source-url'} // $json->{'repo-url'}
            // $json->{support}->{source};

        for ( $url ) {
            s/^\s+|\s+$//g;
            $_ .= '.git'      if m{^git://}    and not m{\.git$};
            $_  =~ s/\.git$// if m{^https?://};
            $_ .= '/'         if m{^https?://} and not m{/$}    ;
        }

        $projects->{$name}->{'url'} = $url;
        $projects->{$name}{success} = 0;

        my ($home) = $url =~ m[(?:git|https?)://([\w\.]+)/];
        if ($home) {
            if ($home =~ /github/) {
                $projects->{$name}->{'home'} = 'github';
                my ($auth, $repo_name) = $url  =~ m[
                    (?:git|https?)://
                        \Q$home\E/
                        ([^/]+)/        # auth
                        ([^/]+)         # repo name
                        (?:\.git|/)     # handle .git or https ending
                ]x;

                $projects->{$name}->{'auth'} = $auth;
                $projects->{$name}->{'repo_name'} = $repo_name;
            } else {
                $stats->error("Unsupported repo host: $home");
                next;
            }
        }
        else {
            $stats->error("Invalid source-url found: $url ($proj)");
            next;
        }
        $projects->{$name}->{'badge_panda'} = defined $json->{'source-url'};
        $projects->{$name}->{'badge_panda_nos11'} = defined $json->{'source-url'} && !defined $json->{'provides'};
        $projects->{$name}->{'description'} = $json->{'description'};
    }

    my $cached_projects = eval {
        decode_json(read_file($self->p6p->output_dir . 'proto.json', binmode => ':encoding(UTF-8)'))
    };

    foreach my $project_name (keys %$projects) {
        my $project = $projects->{$project_name};
        $project->{name} = $project_name;
        print "$stats->{success}/$total $project_name\n";
        if (!$project->{home}) {
            delete $projects->{$project_name};
            next;
        }
        my $home = $hosts->{$project->{home}};
        if (!$home) {
            $stats->error("Could not handle specified host");
            next;
        }
        if ($home->set_project_info($project, $cached_projects->{$project_name})) {
            $stats->succeed;
        }
        print $project->{description}, "\n\n";

        if ($project->{travis}) {
            my $travis_url = 'https://api.travis-ci.org/repos/'
                . "$project->{auth}/$project->{repo_name}/builds";

            my @builds = eval {
                my $res = $ua->get(
                    $travis_url
                    => { Accept => 'application/vnd.travis-ci.2+json' }
                )->res->json->{builds};

                @$res;
            }; $@ and warn "Error fetching travis status: $@\n";

            $project->{travis_status} = __get_travis_status( @builds );
         }
    }
    return $projects;
}

sub __get_travis_status {
    my @builds = @_;

    return 'unknown' unless @builds;
    my $state = $builds[0]->{state};

    return $state    if $state =~ /cancel|pend/;
    return 'error'   if $state =~ /error/;
    return 'failing' if $state =~ /fail/;
    return 'passing' if $state =~ /pass/;
    return 'unknown';
}

1;