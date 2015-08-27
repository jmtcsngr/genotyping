use utf8;

package WTSI::NPG::Genotyping::VCF::ReadyPlexCallsTest;

use strict;
use warnings;

use base qw(Test::Class);
use Test::More tests => 4;
use Test::Exception;
use File::Slurp qw(read_file);
use File::Temp qw(tempdir);
use JSON;
use Log::Log4perl;
use WTSI::NPG::iRODS;

our $LOG_TEST_CONF =  './etc/log4perl_tests.conf';

Log::Log4perl::init($LOG_TEST_CONF);

# test for ready_qc_calls.pl
# TODO Later merge this into ScriptsTest.pm, but keep separate for now for quicker testing in development (running ScriptsTest.pm takes ~11 minutes!)

# Requirements:
# - Pipeline database for sample names (or option to read from file)
# - Appropriate (dummy?) Fluidigm/Sequenom files in iRODS
# - Run script and validate VCF output


our $READY_QC_CALLS = './bin/ready_qc_calls.pl';

my $irods;
my $irods_tmp_coll;
my $pid = $$;
my $data_path = './t/vcf';
my $tmp;
my $snpset_path;

# fluidigm test data
my $f_expected_vcf = $data_path."/fluidigm.vcf";
my $f_reference_name = "Homo_sapiens (1000Genomes)";
my $f_snpset_id = 'qc';
my $f_snpset_filename = 'qc_fluidigm_snp_info_GRCh37.tsv';
my @f_input_files = qw(fluidigm_001.csv fluidigm_002.csv
                     fluidigm_003.csv fluidigm_004.csv);
my @f_sample_ids = qw(sample_001 sample_002 sample_003 sample_004);
my $f_sample_json = $data_path."/fluidigm_samples.json";
my $f_params_name = "params_fluidigm.json";

# sequenom test data
my $s_expected_vcf = $data_path."/sequenom.vcf";
my $s_reference_name = "Homo_sapiens (1000Genomes)";
my $s_snpset_id = 'W30467';
my $s_snpset_filename = 'W30467_snp_set_info_GRCh37.tsv';
my @s_input_files = qw(sequenom_001.csv sequenom_002.csv
                       sequenom_003.csv sequenom_004.csv);
my @s_sample_ids = qw(sample_001 sample_002 sample_003 sample_004);
my $s_sample_json = $data_path."/sequenom_samples.json";
my $s_params_name = "params_sequenom.json";

my $log = Log::Log4perl->get_logger();

sub make_fixture : Test(setup) {
    $tmp = tempdir("ready_plex_test_XXXXXX", CLEANUP => 1);
    $log->info("Created temporary directory $tmp");
    $irods = WTSI::NPG::iRODS->new;
    $irods_tmp_coll = $irods->add_collection("ReadyPlexCallsTest.$pid");
}

sub setup_fluidigm {
    # add some dummy fluidigm CSV files to the temporary collection
    # add sample and snpset names to metadata
    for (my $i=0;$i<@f_input_files;$i++) {
        my $input = $f_input_files[$i];
        my $ipath = $irods_tmp_coll."/".$input;
        $irods->add_object($data_path."/".$input, $ipath);
        $irods->add_object_avu($ipath,'dcterms:identifier',$f_sample_ids[$i]);
        $irods->add_object_avu($ipath, 'fluidigm_plex', $f_snpset_id);
    }
    # add chromosome_json to temp irods
    my $chromosome_json_filename = "chromosome_lengths_GRCh37.json";
    my $cjson = $data_path."/".$chromosome_json_filename;
    my $cjson_irods = $irods_tmp_coll."/".$chromosome_json_filename;
    $irods->add_object($cjson, $cjson_irods);
    $snpset_path = $irods_tmp_coll."/".$f_snpset_filename;
    $irods->add_object($data_path."/".$f_snpset_filename, $snpset_path);
    $irods->add_object_avu($snpset_path, 'chromosome_json', $cjson_irods);
    $irods->add_object_avu($snpset_path, 'fluidigm_plex', $f_snpset_id);
    $irods->add_object_avu($snpset_path, 'reference_name', $f_reference_name);
    # write JSON config file with test params
    my %params = (
        "irods_data_path"      => $irods_tmp_coll,
        "platform"             => "fluidigm",
        "reference_name"       => $f_reference_name,
        "reference_path"       => $irods_tmp_coll,
        "snpset_name"          => $f_snpset_id,
    );
    my $params_path_fluidigm = $tmp."/".$f_params_name;
    open my $out, ">", $params_path_fluidigm ||
        $log->logcroak("Cannot open test parameter path '",
                       $params_path_fluidigm, "'");
    print $out to_json(\%params);
    close $out ||
        $log->logcroak("Cannot close test parameter path '",
                       $params_path_fluidigm, "'");
}

sub setup_sequenom {
    # add some dummy fluidigm CSV files to the temporary collection
    # add sample and snpset names to metadata
    for (my $i=0;$i<@s_input_files;$i++) {
        my $input = $s_input_files[$i];
        my $ipath = $irods_tmp_coll."/".$input;
        $irods->add_object($data_path."/".$input, $ipath);
        $irods->add_object_avu($ipath,'dcterms:identifier',$s_sample_ids[$i]);
        $irods->add_object_avu($ipath, 'sequenom_plex', $s_snpset_id);
    }
    # add chromosome_json to temp irods
    my $chromosome_json_filename = "chromosome_lengths_GRCh37.json";
    my $cjson = $data_path."/".$chromosome_json_filename;
    my $cjson_irods = $irods_tmp_coll."/".$chromosome_json_filename;
    $irods->add_object($cjson, $cjson_irods);
    $snpset_path = $irods_tmp_coll."/".$s_snpset_filename;
    $irods->add_object($data_path."/".$s_snpset_filename, $snpset_path);
    $irods->add_object_avu($snpset_path, 'chromosome_json', $cjson_irods);
    $irods->add_object_avu($snpset_path, 'sequenom_plex', $s_snpset_id);
    $irods->add_object_avu($snpset_path, 'reference_name', $s_reference_name);
    # write JSON config file with test params
    my %params = (
        "irods_data_path"      => $irods_tmp_coll,
        "platform"             => "sequenom",
        "reference_name"       => $s_reference_name,
        "reference_path"       => $irods_tmp_coll,
        "snpset_name"          => $s_snpset_id,
    );
    my $params_path_sequenom = $tmp."/".$s_params_name;
    open my $out, ">", $params_path_sequenom ||
        $log->logcroak("Cannot open test parameter path '",
                       $params_path_sequenom, "'");
    print $out to_json(\%params);
    close $out ||
        $log->logcroak("Cannot close test parameter path '",
                       $params_path_sequenom, "'");
}

sub teardown : Test(teardown) {
    $irods->remove_collection($irods_tmp_coll);
}

sub test_ready_calls_fluidigm : Test(2) {
    setup_fluidigm();

    my $vcf_out = "$tmp/test_fluidigm.vcf";
    my $params_path_fluidigm = $tmp."/".$f_params_name;
    my $cmd = join q{ }, "$READY_QC_CALLS",
                         "--config $params_path_fluidigm",
                         "--sample-json $f_sample_json",
                         "--logconf $LOG_TEST_CONF",
                         "--out $vcf_out";
    ok(system($cmd) == 0, 'Wrote Fluidigm calls to VCF');
    my @got_lines = read_file($vcf_out);
    @got_lines = grep !/^[#]{2}(fileDate|reference)=/, @got_lines;
    my @expected_lines = read_file($f_expected_vcf);
    @expected_lines = grep !/^[#]{2}(fileDate|reference)=/, @expected_lines;
    is_deeply(\@got_lines, \@expected_lines,
              "Fluidigm VCF output matches expected values");

}

sub test_ready_calls_sequenom : Test(2) {
    setup_sequenom();

    my $vcf_out = "$tmp/test_sequenom.vcf";
    my $params_path_sequenom = $tmp."/".$s_params_name;
    my $cmd = join q{ }, "$READY_QC_CALLS",
                         "--config $params_path_sequenom",
                         "--sample-json $s_sample_json",
                         "--logconf $LOG_TEST_CONF",
                         "--out $vcf_out";
    ok(system($cmd) == 0, 'Wrote Sequenom calls to VCF');
    my @got_lines = read_file($vcf_out);
    @got_lines = grep !/^[#]{2}(fileDate|reference)=/, @got_lines;
    my @expected_lines = read_file($s_expected_vcf);
    @expected_lines = grep !/^[#]{2}(fileDate|reference)=/, @expected_lines;
    is_deeply(\@got_lines, \@expected_lines,
              "Sequenom VCF output matches expected values");

}

return 1;
