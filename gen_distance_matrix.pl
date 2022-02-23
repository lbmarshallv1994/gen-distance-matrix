use Parse::CSV;
use List::Util qw(min);
use List::MoreUtils qw(natatime);
use Config::Tiny;
use Data::Dumper;
use DBI;
use DateTime;  
use Time::Piece;
use Spreadsheet::Read qw(ReadData rows row cellrow);
use LWP::Simple;
use Geo::Coder::Bing;
use JSON::Parse qw(parse_json assert_valid_json);
use Excel::Writer::XLSX;
use Net::OpenSSH;
use JSON;

sub geo_request{
    my( $api_settings_ref, $origin_ref, $dest_ref) = @_;
    my %api_settings = %$api_settings_ref;
    unless( $api_settings{"key"} ){
        $logger->error("API key was not found");
        return undef;
    }
    #set up API connection
    my $bing = Geo::Coder::Bing->new($api_settings{"key"});  
    # Y x dest_ref_size <= max_product
    # Y <= max_product / dest_ref_size
    # y = floor(max_product/dest_ref_size)
    my @origins = @{ $origin_ref };
    my @results;
    # find out how many coords we can process per request.
    my $budget = int(%api_settings{"max_product"} / scalar(@origins));
    print("data being chunked into ".$budget.".\n");
    my $it = natatime $budget, @origins;
    my $real_index = 0;
    my $uri = URI->new($api_settings{"matrix_url"}."?key=".$bing->{key});
    print("URI to post: $uri\n");
    while (my @coords = $it->())
    {
        my %content = (
            origins => \@coords, 
            destinations => $dest_ref, 
            travelMode => $api_settings{"travel_mode"},
            timeUnit => $api_settings{"time_unit"}, 
            distanceUnit => $api_settings{"distance_unit"}
        );
        my $json = encode_json \%content;   
        #print("JSON content: $json\n");
        my $rest_req = _post_request($bing,$uri,$json);
        # print Dumper $rest_req;
        #calculate the distance matrix for this chunk of origins.
        my @distance_matrix = eval{$rest_req->{results}};
         if(@distance_matrix){
            for my $ref (@distance_matrix) {
                for (@$ref){
                    my %dist;
                    $dist{originIndex} = $_->{originIndex} + $real_index;
                    $dist{destinationIndex} = $_->{destinationIndex};
                    $dist{travelDistance} = $_->{travelDistance}; 
                    $dist{travelDuration} = $_->{travelDuration}; 
                    push(@results,\%dist);
                    }
            }
           # print(Dumper \@results);
            $real_index += min($budget,scalar(@coords));
            print("setting index to ".$real_index."\n");
        }               
    }
    return @results;
}

sub _post_request {
    my ($bing, $uri,$form) = @_;
    return unless $uri;
 
    my $res = $bing->{response} = $bing->ua->post($uri,'Content-Length' => 3500,'Content-Type' => 'application/json',Content => $form);
    unless($res->is_success){
        print("API ERROR\n");
        print(Dumper $res);
        return;
    }
 
    # Change the content type of the response from 'application/json' so
    # HTTP::Message will decode the character encoding.
    $res->content_type('text/plain');
 
    my $content = $res->decoded_content;
    return unless $content;
 
    my $data = eval { from_json($content) };
    return unless $data;
 
    my @results = @{ $data->{resourceSets}[0]{resources} || [] };
    return wantarray ? @results : $results[0];
}

# start the stopwatch
my $total_time_start = time();

#parse config
my $config = Config::Tiny->read( "config.ini", 'utf8' );

#set up bing
my $api_key = $config->{API}{key};
my $api_max_product = $config->{API}{max_product};
my %api_settings = (
    "key" => $config->{API}{key},
    "max_product" => $config->{API}{max_product}, 
    "travel_mode" => $config->{API}{travel_mode}, 
    "time_unit" => $config->{API}{time_unit},
    "distance_unit" => $config->{API}{distance_unit},
    "matrix_url" => $config->{API}{matrix_url}
);

#set up SSH
my $ssh_db_port = $config->{SSH}{db_port};
my $key_name = $config->{SSH}{keyname};
my $ssh_host = $config->{SSH}{host};
my $ssh; 

#set up SQL
#database name
my $db = $config->{PSQL}{db};
#database hostname
my $host = $config->{PSQL}{host};
#database port
my $port = $config->{PSQL}{port};
#database username
my $usr = $config->{PSQL}{username};
# database password
my $pwrd = $config->{PSQL}{password};
# database table
my $dbtable = $config->{PSQL}{dbtable};
my $dsn = "dbi:Pg:dbname='$db';host='$host';port='$port';";

#set up SSH tunnel
if( $config->{SSH}{enabled} eq 'true'){
    $ssh = Net::OpenSSH->new($ssh_host,key_path => $key_name, master_opts => [-L => "127.0.0.1:$port:localhost:$ssh_db_port"]) or die;
}

#set up database connection
my $dbh =DBI->connect($dsn, $usr, $pwrd, {AutoCommit => 0}) or die ( "Couldn't connect to database: " . DBI->errstr );

# get org unit addr
my $org_st = $dbh->prepare("SELECT ou.id AS org_unit, aoa.latitude, aoa.longitude FROM actor.org_unit ou JOIN actor.org_address aoa ON aoa.id = COALESCE(ou.billing_address, ou.mailing_address, ou.holds_address, ou.ill_address) where longitude is not null and latitude is not null order by org_unit");
print("Retrieving org unit addresses\n");
my @origins;
my @destinations;
my @hub_ids;
$org_st->execute();
for((0..$org_st->rows-1)){
    my $sql_hash_ref = $org_st->fetchrow_hashref;
    my %ocoord; 
    $ocoord{'latitude'} = $sql_hash_ref->{'latitude'};
    $ocoord{'longitude'} = $sql_hash_ref->{'longitude'};
    my %dcoord; 
    $dcoord{'latitude'} = $sql_hash_ref->{'latitude'};
    $dcoord{'longitude'} = $sql_hash_ref->{'longitude'};
    push(@hub_ids, $sql_hash_ref->{'org_unit'});
    push(@origins, \%ocoord);
    push(@destinations, \%dcoord);
}
$org_st->finish();

print("Calculating distance matrix\n");

my @distance_matrix = geo_request(\%api_settings,\@origins,\@destinations);
if(@distance_matrix){
    print "Building SQL delete statement\n";
    my $clear = "DELETE FROM $dbtable";
    my $cls_st = $dbh->prepare($clear);
     print "Clearing old data from $dbtable\n";
    $cls_st->execute() or die $DBI::errstr;
    $cls_st->finish();
    $dbh->commit or die $DBI::errstr;
    print "Building SQL insert statement\n";
    my $insert = "INSERT INTO $dbtable (origin, destination, travel_distance, travel_duration)";
    my @values;
    for my $ref (@distance_matrix) {
            my %dist = %$ref;
            print(Dumper($ref));
            my $origin = $hub_ids[$dist{originIndex}];
            my $destination = $hub_ids[$dist{destinationIndex}];
            my $distance = $dist{travelDistance};
            my $duration = $dist{travelDuration};
            push(@values,"($origin, $destination, $distance, $duration)");
            
    }
    $insert.=" VALUES ".join(",",@values) if scalar(@values);
    print("Inserting values into $dbtable\n");
    my $ins_st = $dbh->prepare($insert);
    print("\n\n========== DB STATEMENT ==========\n");
    print($insert);
    $ins_st->execute() or die $DBI::errstr;
    $ins_st->finish();
    $dbh->commit or die $DBI::errstr;
}
else{
    print(Dumper @distance_matrix);
    print("API failed to calculate distance matrix\n");
}
# close connection to database       
$dbh->disconnect;
#log completion time   
my $complete_time = (time() - $total_time_start)/60.0;
print("\n\nscript finished in $complete_time minutes\n");
