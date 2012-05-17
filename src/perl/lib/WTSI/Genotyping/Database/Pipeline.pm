use utf8;

package WTSI::Genotyping::Database::Pipeline;

use strict;
use warnings;
use Carp;

use WTSI::Genotyping::Database;
use WTSI::Genotyping::Schema;

our @ISA = qw(WTSI::Genotyping::Database);
our $AUTOLOAD;

our $genders_ini = 'genders.ini';
our $methods_ini = 'methods.ini';
our $relations_ini = 'relations.ini';
our $snpsets_ini = 'snpsets.ini';
our $states_ini = 'states.ini';

=head2 new

  Arg [1]    : name => string
  Arg [2]    : inifile => string
  Arg [3]    : dbfile => string
  Arg [3]    : overwrite => boolean
  Example    : WTSI::Genotyping::Database::Pipeline->new
                 (name => 'my_database', inifile => 'my_database.ini',
                  dbfile => 'pipeline.db', overwrite => 1)
  Description: Returns a new database handle configured from an
               .ini-style file.
  Returntype : WTSI::Genotyping::Database
  Caller     : general

=cut

sub new {
   my $class = shift;
   my %args = @_;

   my $self = $class->SUPER::new(%args);
   $self->{_dbfile} = $args{dbfile};
   $self->{_overwrite} = $args{overwrite};
   bless($self, $class);

   return $self->initialize;
}

sub initialize {
  my $self = shift;

  my $ini = Config::IniFiles->new(-file => $self->inifile);

  my $ds = $self->data_source;
  my ($base, $file) = $ds =~ m/^(dbi:SQLite:dbname=)(.*)/;
  unless ($base && $file) {
    croak "Failed to parse datasource string '$ds' in " . $self->inifile, "\n";
  }

  # Override the default data source if a database file was given in
  # the constructor
  if ($self->dbfile) {
    $file = $self->dbfile;
    $self->data_source($base . $self->dbfile);
  }

  if (-e $file) {
    if ($self->{_overwrite}) {
      unlink($file);
      $self->create($file, $ini);
    }
  }
  else {
    $self->create($file, $ini);
  }

  return $self;
}


=head2 create

  Arg [1]    : Database file
  Arg [2]    : Config::IniFiles ini file
  Example    : $db->create($file, $ini)
  Description: Writes the SQLite database file. This is called automatically
               by the constructor, but may be called at any time to re-write
               the database file.
  Returntype : WTSI::Genotyping::Database::Pipeline
  Caller     : constructor, general

=cut

sub create {
  my ($self, $file, $ini) = @_;

  my $sql_path = $ini->val($self->name, 'sqlpath');
  my $sqlite = $ini->val($self->name, 'sqlite');

  unless ($sql_path) {
    croak "Failed to create database: sql_path declaration is missing from " .
      $self->inifile, "\n";
  }
  unless (-e $sql_path) {
    croak "Failed to create database: DDL file '$sql_path' is missing\n";
  }
  unless ($sqlite) {
    croak "Failed to create database: sqlite declaration is missing from " .
      $self->inifile, "\n";
  }

  if (-e $file) {
    croak "Failed to create database: database '$file' already exists\n";
  }
  else {
    system("$sqlite $file < $sql_path") == 0
      or croak "Failed to create SQLite database '$file': $?";
  }

  return $self;
}

=head2 populate

  Arg [1]    : None
  Example    : $db->populate
  Description: Populates the dictionary tables of a database from the
               default .ini files located in the 'inipath' path given
               in the database configuration (See
               WTSI::Genotyping::Database::configure). May be called
               safely multiple times on the same .ini data.
  Returntype : WTSI::Genotyping::Database::Pipeline
  Caller     : general

=cut

sub populate {
  my $self = shift;

  my $ini = Config::IniFiles->new(-file => $self->inifile);
  my $ini_path = $ini->val($self->name, 'inipath');

  unless ($self->is_connected) {
    croak "Failed to populate database: not connected\n";
  }

  $self->_populate_addresses;
  $self->_populate_genders("$ini_path/$genders_ini");
  $self->_populate_relations("$ini_path/$relations_ini");
  $self->_populate_states("$ini_path/$states_ini");
  $self->_populate_methods("$ini_path/$methods_ini");
  $self->_populate_snpsets("$ini_path/$snpsets_ini");

  return $self;
}


=head2 connect

  See WTSI::Genotyping::Database.

=cut

sub connect {
  my $self = shift;
  my %args = @_;

  unless ($self->is_connected) {
    $self->{_schema} = WTSI::Genotyping::Schema->connect($self->data_source,
                                                         $self->username,
                                                         $self->password,
                                                         \%args);
  }

  return $self;
}


=head2 is_connected

  See WTSI::Genotyping::Database.

=cut

sub is_connected {
  my $self = shift;
  return defined $self->dbh && $self->dbh->ping;
}


=head2 disconnect

  See WTSI::Genotyping::Database.

=cut

sub disconnect {
  my $self = shift;
  if ($self->is_connected) {
    $self->schema->storage->disconnect;
  }

  return $self;
}


=head2 dbh

  See WTSI::Genotyping::Database.

=cut

sub dbh {
  my $self = shift;
  if ($self->schema) {
    return $self->schema->storage->dbh;
  }
}


=head2 dbfile

  Arg [1]    : None
  Example    : $db->dbfile
  Description: Returns the current database file.
  Returntype : string
  Caller     : general

=cut

sub dbfile {
  my $self = shift;
  return $self->{_dbfile};
}

=head2 in_transaction

  Arg [1]    : Subroutine reference
  Arg [n]    : Subroutine arguments
  Example    : $db->in_transaction(sub {  my $ds = shift;
                                          my @sm = @_;
                                          foreach (@sm) {
                                            $ds->add_to_samples($_);
                                          }
                                        }, $dataset, @samples);
  Description: Executes a subroutine in the context of a transaction
               which will rollback on error.
  Returntype : As subroutine.
  Caller     : general

=cut

sub in_transaction {
  my ($self, $code, @args) = @_;

  my @result;

  eval {
    @result = $self->schema->txn_do($code, @args);
  };

  if ($@) {
    my $error = $@;
    if ($error =~ /Rollback failed/) {
      croak "$error.\nRollback failed!\nWARNING: data may be inconsistent.\n";
    } else {
      croak "$error.\nRollback successful\n";
    }
  };

  return wantarray ? @result : $result[0];
}


=head2 schema

  Arg [1]    : None
  Example    : $db->schema
  Description: Returns the current database schema object.
  Returntype : WTSI::Genotyping::Schema
  Caller     : general

=cut

sub schema {
 my $self = shift;
 return $self->{_schema};
}


=head2 address

Returns a DBIx::Class::ResultSet for the registered source 'address'.

=cut

=head2 dataset

Returns a DBIx::Class::ResultSet for the registered source 'dataset'.

=cut


=head2 datasupplier

Returns a DBIx::Class::ResultSet for the registered source 'datasupplier'.

=cut


=head2 gender

Returns a DBIx::Class::ResultSet for the registered source 'gender'.

=cut


=head2 method

Returns a DBIx::Class::ResultSet for the registered source 'method'.

=cut


=head2 piperun

Returns a DBIx::Class::ResultSet for the registered source 'piperun'.

=cut


=head2 plate

Returns a DBIx::Class::ResultSet for the registered source 'plate'.

=cut


=head2 result

Returns a DBIx::Class::ResultSet for the registered source 'result'.

=cut


=head2 snp

Returns a DBIx::Class::ResultSet for the registered source 'snp'.

=cut


=head2 snpset

Returns a DBIx::Class::ResultSet for the registered source 'snpset'.

=cut


=head2 state

Returns a DBIx::Class::ResultSet for the registered source 'state'.

=cut


=head2 well

Returns a DBIx::Class::ResultSet for the registered source 'well'.

=cut


# Populates plate well addresses dictionary with the two styles of
# address label used.
sub _populate_addresses {
  my ($self) = @_;

  foreach my $row (1..16) {
    foreach my $col (1..24) {
      my $label1 = sprintf("%c%02d", 64+ $row, $col);
      my $label2 = sprintf("%c%d", 64+ $row, $col);
      $self->address->find_or_create({label1 => $label1,
                                      label2 => $label2});
    }
  }
}

# Populates snpsets dictionary (Infinium and Sequenom SNP sets).
sub _populate_snpsets {
  my ($self, $inifile) = @_;
  return $self->_insert_list_from_ini('Snpset', $inifile, 'name');
}

# Populates the gender dictionary.
sub _populate_genders {
  my ($self, $inifile) = @_;
  return $self->_insert_from_ini('Gender', $inifile);
}

# Populates the analysis method dictionary.
sub _populate_methods {
  my ($self, $inifile) = @_;
  return $self->_insert_from_ini('Method', $inifile);
}

# Populates the sample-sample relation method dictionary.
sub _populate_relations {
  my ($self, $inifile) = @_;
  return $self->_insert_from_ini('Relation', $inifile);
}

# Populates the sample state dictionary.
sub _populate_states {
  my ($self, $inifile) = @_;
  return $self->_insert_from_ini('State', $inifile);
}

sub _insert_list_from_ini {
  my ($self, $class, $inifile, $param) = @_;

  my @objects;
  my $ini = Config::IniFiles->new(-file => $inifile);
  foreach my $sect ($ini->Sections) {
    foreach my $elt ($ini->val($sect, $param)) {
      push @objects,
        $self->schema->resultset($class)->find_or_create({$param => $elt});
    }
  }

  return \@objects;
}

sub _insert_from_ini {
  my ($self, $class, $inifile) = @_;

  my @objects;
  my $ini = Config::IniFiles->new(-file => $inifile);
  foreach my $sect ($ini->Sections) {
    my %args;
    foreach my $param ($ini->Parameters($sect)) {
      $args{$param} = $ini->val($sect, $param);
    }

    push @objects, $self->schema->resultset($class)->find_or_create(\%args);
  }

  return \@objects;
}


# Autoloads methods corresponding to the Schema->sources. By default,
# you can do this if you have any Result instance. E.g.
#
# my @samples = $dataset->samples;
#
# However, to obtain a Result instance if you have none, you must do
# something like this. E.g.
#
# my @samples = $db->schema->resultset('Samples')->all;
#
# This autoload permits shortcut methods on the database object for cases
# where there is no Result instance handy. E.g.
#
# my @samples = $db->sample->all;
#
sub AUTOLOAD {
  my $self = shift;
  my $type = ref($self) or croak "$self is not an object\n";

  return if $AUTOLOAD =~ /::DESTROY$/;

  unless ($self->is_connected) {
    croak "$self is not connected\n";
  }

  my $schema = $self->schema;
  my %lookup;
  foreach my $source_name ($schema->sources) {
    my $name = $schema->source($source_name)->name;
    $lookup{$name} = $source_name;
  }

  my $method_name = $AUTOLOAD;
  $method_name =~ s/.*://;
  unless (exists $lookup{$method_name} ) {
    croak "An invalid method `$method_name' was called " .
      "on an object of $type. Permitted methods are [" .
        join(", ", sort keys %lookup) . "]\n";
  }

 SYMBOL_TABLE: {
    no strict qw(refs);

    *$AUTOLOAD = sub {
      my $self = shift;
      return $self->schema->resultset($lookup{$method_name});
    };
  }

  unshift @_, $self;
  goto &$AUTOLOAD;
}

1;

__END__

=head1 NAME

WTSI::Genotyping::Database::Pipeline

=head1 DESCRIPTION

A class for accessing the genotyping pipeline analysis database.

=head1 AUTHOR

Keith James <kdj@sanger.ac.uk>

=head1 COPYRIGHT AND DISCLAIMER

Copyright (c) 2012 Genome Research Limited. All Rights Reserved.

This program is free software: you can redistribute it and/or modify
it under the terms of the Perl Artistic License or the GNU General
Public License as published by the Free Software Foundation, either
version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

=cut