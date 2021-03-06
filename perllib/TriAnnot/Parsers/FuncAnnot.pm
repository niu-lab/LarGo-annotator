#!/usr/bin/env perl

package TriAnnot::Parsers::FuncAnnot;

##################################################
## Documentation POD
##################################################

##################################################
## Included modules
##################################################
## Perl modules
use strict;
use warnings;
use diagnostics;

# CPAN modules
use File::Basename;

## Bioperl modules
use Bio::SearchIO;

## TriAnnot modules
use TriAnnot::Config::ConfigFileLoader;
use TriAnnot::Parsers::Parsers;
use TriAnnot::Tools::Logger;

## Inherits
our @ISA = qw(TriAnnot::Parsers::Parsers);

##################################################
## Methods
##################################################
=head1 TriAnnot::Parsers::FuncAnnot - Methods
=cut

################
# Constructor
################

sub new {

	# Recovers parameters
	my ($class, $attrs_ref) = @_;

	# Check the type of the second argument
	if (ref($attrs_ref) ne 'HASH') {
		$logger->logdie('Error: FuncAnnot.pm constructor is expecting a hash reference as second argument !');
	}

	# Call the constructor of the parent class (TriAnnot::Programs::Programs)
	my $self = $class->SUPER::new($attrs_ref);

	# Set specific object attributes
	$self->{'Annotations'} = {}; # Each key is a sequence ID and each value is the corresponding annotation

	bless $self => $class;

	return $self;
}


#############################################
## Parameters/variables initializations
#############################################

sub setParameters {
	my ($self, $parameters) = @_;

	# Call parent class method (See Programs.pm module for more information)
	$self->SUPER::setParameters($parameters);

	# Store some path and names in the current object for easier access
	$self->_managePathsAndNames();
}


sub _managePathsAndNames {

	# Recovers parameters
	my $self = shift;

	# Full paths
	$self->{'gffToAnnotateFullPath'} = $self->{'directory'} . '/' . $TRIANNOT_CONF{'DIRNAME'}->{'GFF_files'} . '/' . basename($self->{'gff_to_annotate'});
}


##################
# Method parse() #
##################

sub _parse {
	my $self = shift;

	# Initializations
	my @FuncAnnotFeatures = ();
	$self->{'nbAnnotatedFeature'} = 0;

	# Display a warning message when the annotation result file is missing
	if (! -e $self->{'fullFileToParsePath'}) {
		$logger->logwarn('FuncAnnot output file is missing (' . $self->{'fullFileToParsePath'} . '). There will be no functional annotation in the final GFF file !');
	}

	# Display a warning message when the GFF file created during MergeGeneModels execution is missing
	if (! -e $self->{'gffToAnnotateFullPath'}) {
		$logger->logwarn('Uncomplete GFF file from the previous step (MergeGeneModels - ' . $self->{'gffToAnnotateFullPath'} . ') does not exists in the GFF folder. Parse method will return an empty feature array !');
		return @FuncAnnotFeatures;
	}

	# Parse FuncAnnot result file to recover the functional annotation of each sequence
	$self->_loadAnnotationResults();

	# Group the features of the GFF3 file generated by MergeGeneModels
	my $AllFeatureGroupsHashRef = $self->_classGffFeaturesIntoKinshipGroups();

	$logger->info('Available annotations will now be added to existing <' . $self->{'featureTypeToAnnotate'} . '> features:');

	foreach my $groupId (keys %{$AllFeatureGroupsHashRef}) {
		# Initializations
		my $rejectFeatureGroup = 'no';

		foreach my $currentFeature (@{$AllFeatureGroupsHashRef->{$groupId}}) {
			# Discard the feature that don't have the appropriate primary tag
			next if ($currentFeature->primary_tag() ne $self->{'featureTypeToAnnotate'});

			# Initializations
			my $currentFeatureToAnnotateId = ($currentFeature->get_tag_values('ID'))[0];

			# Add annotation if it exist or set the group as rejected
			if (defined($self->{'Annotations'}->{$currentFeatureToAnnotateId})) {
				$self->_addAnnotation($currentFeature);
				$rejectFeatureGroup = $self->_needToRejectFeature($currentFeature, $TRIANNOT_CONF{$self->{'programName'}}->{'AnnotationSteps'}->{'NoResultMessage'});
			} else {
				$logger->info('  -> ' . 'Feature <' . $currentFeatureToAnnotateId . '> has not been annotated during the last ' . $self->{'programName'} . ' execution and will therefore be discarded !');
				$rejectFeatureGroup = 'yes';
			}
		}

		# Reject or store the full feature group
		push(@FuncAnnotFeatures, @{$AllFeatureGroupsHashRef->{$groupId}}) if ($rejectFeatureGroup eq 'no');
	}

	# Display the number of annotated features or die if no feature has been annotated
	if ($self->{'nbAnnotatedFeature'} > 0) {
		$logger->info('');
		$logger->info('Number of annotated ' . $self->{'featureTypeToAnnotate'} . ': ' . $self->{'nbAnnotatedFeature'});
	} else {
		$logger->logdie('No ' . $self->{'featureTypeToAnnotate'} . ' annotated ! Something must have gone wrong during the functionnal annotation procedure..');
	}

	return @FuncAnnotFeatures;
}


#######################
## Internal Methods
#######################

sub _classGffFeaturesIntoKinshipGroups {

	# Recovers parameters
	my $self = shift;

	# Initializations
	my %allFeatureGroups = ();
	my $currentFirstLevelFeatureId = '';

	# Log
	$logger->info('The features of the GFF file to annotate will now be classed into kinship groups');
	$logger->info('');

	# Open the GFF3 file generated by MergeGeneModels
	my $gffIO = Bio::Tools::GFF->new ( '-file' => $self->{'gffToAnnotateFullPath'}, '-gff_version' => "3" );

	# Browse and class all the features of the GFF file into groups based on their kinship
	while (my $currentFeature = $gffIO->next_feature()) {
		# Reject "region" features by default
		next if ($currentFeature->primary_tag() eq 'region');

		if ($currentFeature->has_tag('Parent') or $currentFeature->has_tag('Derives_from')) {
			# Child feature (or grandchild feature) of the last main feature
			push(@{$allFeatureGroups{$currentFirstLevelFeatureId}}, $currentFeature);
		} else {
			# First level feature (ie. feature with no parents)
			$currentFirstLevelFeatureId = ($currentFeature->get_tag_values('ID'))[0];
			$allFeatureGroups{$currentFirstLevelFeatureId} = [$currentFeature];
		}
	}

	return \%allFeatureGroups;
}


sub getSoftList {

	# Recovers parameters
	my $self = shift;

	# Initializations
	my %Soft_list;
	my @Clean_soft_list = ();

	# Add each programs used during the various step of the functional annotation procedure to the list of software
	foreach my $Current_step (sort keys %{$TRIANNOT_CONF{$self->{'programName'}}->{AnnotationSteps}}) {
		if ($Current_step =~ /STEP/) {
			if (defined($TRIANNOT_CONF{$self->{'programName'}}->{AnnotationSteps}->{$Current_step}->{'programName'})) {
				my $software = $TRIANNOT_CONF{$self->{'programName'}}->{AnnotationSteps}->{$Current_step}->{'programName'};
				push(@Clean_soft_list, $software . '(' . $TRIANNOT_CONF{PATHS}->{soft}->{$software}->{'version'} . ')_' . $Current_step);
			}
		}
	}

	return \@Clean_soft_list;
}


sub getDbList {

	# Recovers parameters
	my $self = shift;

	# Initializations
	my %Db_list;
	my @Clean_db_list = ();

	# Collect a list of database/databank used during the annotation procedure (No repetition)
	foreach my $Current_step (sort keys %{$TRIANNOT_CONF{$self->{'programName'}}->{AnnotationSteps}}) {
		if ($Current_step =~ /STEP/) {
			if (defined($self->{'database_' . $Current_step})) {
				my $databank = $self->{'database_' . $Current_step};
				push(@Clean_db_list, $databank . '(' . $TRIANNOT_CONF{PATHS}->{db}->{$databank}->{'version'} . ')_' . $Current_step );
			}
		}
	}

	# Return a reference to a list of database
	return \@Clean_db_list;
}


sub _needToRejectFeature {

	# Recovers parameters
	my ($self, $currentFeature, $noResultMessage) = @_;

	return 'no';
}



sub _loadAnnotationResults {

	# Recovers parameters
	my $self = shift;

	# Initializations
	my ($Sequence_ID, $Annotation_result) = ('', '');

	# Log
	$logger->info('Recovering the annotation of each <' . $self->{'featureTypeToAnnotate'} . '> feature from the following file: ' . $self->{'fileToParse'});
	$logger->info('');

	# Read functional annotation result file and store its content into a hash table
	open(ANNOT, '<' . $self->{'fullFileToParsePath'}) or $logger->logdie('Error: Cannot open/read file: ' . $self->{'fullFileToParsePath'});
	while(<ANNOT>){
		# Split the current line
		chomp($_);
		($Sequence_ID, $Annotation_result) = split(/\t/, $_);

		# Update the object attribute that store all the sequence annotations
		$self->{'Annotations'}->{$Sequence_ID} = $Annotation_result;
	}
	close(ANNOT);

	return 0; # Success
}


sub _addAnnotation {

	# Recovers parameters
	my ($self, $currentFeature) = @_;

	# Initializations
	my $featureId = join(',', $currentFeature->get_tag_values('ID'));

	# Log
	$logger->info('  -> ' . 'Feature <' . $featureId . '> will now be updated');

	# Functionnal annotation result is a string composed of a series of key=value couples separted by a semicolon
	my @splittedAnnotation = split(';', $self->{'Annotations'}->{$featureId});

	foreach my $annotation_couple (@splittedAnnotation) {

		# Split each couples to isolate attribute's name from its values
		my ($key, $values) = split('=', $annotation_couple);

		# Separate values from each other
		my @values = split(',', $values);

		# Check if we overwrite an existing field in the source gff file
		if ($currentFeature->has_tag($key)) {
			$logger->logwarn('The "' . $key . '" attribute already exists for feature with ID ' . $featureId . ': "' . join(',', $currentFeature->get_tag_values($key)) . '" will be replace by "' . $values . '"');
			$currentFeature->remove_tag($key);
		}

		# Add annotation to attribute hash table
		foreach my $attributeValue (@values) {
			$currentFeature->add_tag_value($key, $attributeValue);
		}
	}

	$self->{'nbAnnotatedFeature'}++;

	return 0; #Success
}

1;
