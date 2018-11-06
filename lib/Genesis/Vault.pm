package Genesis::Vault;
use strict;
use warnings;

use Genesis;
use Genesis::UI;

### Class Variables {{{
my (@all_vaults, $default_vault, $current_vault);
# }}}

### Class Methods {{{

# new - raw instantiation of a vault object {{{
sub new {
	my ($class, $url, $name, $verify) = @_;
	return bless({
			url    => $url,
			name   => $name,
			verify => $verify ? 1 : 0 # Cleans out JSON::Boolean types
		}, $class);
}

# }}}
# attach - builder for vault based on loaded environment {{{
sub attach {
	my ($class, $target_url, $insecure) = @_;

	bail "#R{[ERROR]} Expecting vault target '$target_url' to be a url"
		unless _target_is_url($target_url);

	($target_url, my @targets) = _get_targets($target_url);
	if (scalar(@targets) <1) {
		bail "#R{[ERROR]} Safe target for #M{%s} not found.  Please run\n\n".
				 "  #C{safe target <name> \"%s\"%s\n\n".
				 "then authenticate against it using the correct auth method before\n".
				 "re-attempting this command.",
				 $target_url, $target_url,($insecure?" -k":"");
	}
	if (scalar(@targets) >1) {
		bail "#R{[ERROR]} Multiple safe targets found for #M{%s}:\n%s\n".
				 "\nYour ~/.saferc file cannot have more than one target for the given url.\n" .
				 "Please remove any duplicate targets before re-attempting this command.",
				 $target_url, join("", map {" - #C{$_}\n"} @targets);
	}

	my $vault = $class->new($target_url, $targets[0], !$insecure);
	printf STDERR csprintf("\n#yi{Verifying availability of selected vault...}");
	my $status = $vault->status;
	error("#%s{%s}\n", $status eq "ok"?"G":"R", $status);
	bail("#R{[ERROR]} Could not connect to vault") unless $status eq "ok";
	return $vault->set_as_current;
}

# }}}
# target - builder for vault based on locally available vaults {{{
sub target {
	my ($class,$target) = @_;

	my $url;
	if ($target) {
		($url, my @targets) = _get_targets($target);
		if (scalar(@targets) <1) {
			bail "#R{[ERROR]} Safe target \"#M{%s}\" not found.  Please create it\n".
					 "and authorize against it before re-attempting this command.",
					 $target;
		}
		if (scalar(@targets) >1) {
			bail "#R{[ERROR]} Multiple safe targets use url #M{%s}:\n%s\n".
					 "\nYour ~/.saferc file cannot have more than one target for the given url.  Please".
					 "remove any duplicate targets before re-attempting this command.",
					 $url, join("", map {" - #C{$_}\n"} @targets);
		}
	} else {

		die_unless_controlling_terminal("${class}::target");

		my $w = (sort {$b<=>$a} map {length($_->{name})} $class->all)[0];

		my (%uses,@labels,@choices);
		$uses{$_->{url}}++ for $class->all;
		for ($class->all) {
			next unless $uses{$_->{url}} == 1;
			push(@choices, $_->{url});
			push(@labels, [csprintf(
			"#%s{%-*.*s}   #R{%-10.10s} #%s{%s}",
			  $_->{name} eq $class->default->{name} ? "G" : "-",
			     $w, $w, $_->{name},
			                  $_->{url} =~ /^https/ ? ($_->{verify} ? "" : "(noverify)") : "(insecure)",
			                             $_->{name} eq $class->default->{name} ? "Y" : "-",
			                                $_->{url}
			),$_->{name}]);
		}

		my $msg = csprintf("#u{Select Vault:}\n");
		my @invalid_urls = grep {$uses{$_} > 1} keys(%uses);

		if (scalar(@invalid_urls)) {
			$msg .= "\n".
				"Note: One or more vault targets have been omitted because they are alias for\n".
				"      the same URL, which is incompatible with Genesis's distributed model.\n".
				"      If you need one of the omitted targets, please ensure there is only one\n".
				"      target alias that uses its URL.\n"
		}

		$url = prompt_for_choice(
			$msg,
			\@choices,
			$uses{$class->default->{url}} == 1 ? $class->default->{url} : undef,
			\@labels
		)
	}

	my $vault = (grep {$_->{url} eq $url} $class->all)[0];
	printf STDERR csprintf("\n#yi{Verifying availability of selected vault...}");
	my $status = $vault->status;
	error("#%s{%s}\n", $status eq "ok"?"G":"R", $status);
	bail("#R{[ERROR]} Could not connect to vault") unless $status eq "ok";
	return $vault->set_as_current;
}

# }}}
# rebind - builder for rebinding to a previously selected vault (for callbacks) {{{
sub rebind {
	# Special builder with less checking for callback support
	my ($class) = @_;

	bail("Cannot rebind to vault in callback due to missing environment variables!")
		unless $ENV{GENESIS_TARGET_VAULT};

	my $vault = (grep {$_->url eq $ENV{GENESIS_TARGET_VAULT}} @all_vaults)[0];
	return unless $vault;
	return $vault->set_as_current;
}

# }}}
# all - return all known local vaults {{{
sub all {
	unless (@all_vaults) {
		@all_vaults = map {Genesis::Vault->new($_->{url},$_->{name},$_->{verify})}
									sort {$a->{name} cmp $b->{name}}
									@{ read_json_from(run("safe targets --json")) };
	}
	return @all_vaults;
}

# }}}
# default - return the default vault (targeted by system) {{{
sub default {
	unless ($default_vault) {
		my $json = read_json_from(run("safe target --json"));
		$default_vault = Genesis::Vault->new($json->{url},$json->{name},$json->{verify});
	}
	return $default_vault;
}

# }}}
# current - return the last vault returned by attach, target, or rebind {{{
sub current {
	return $current_vault
}
# }}}
# }}}

### Instance Methods {{{

# public accessors: url, name, verify, tls {{{
sub url    { $_[0]->{url};    }
sub name   { $_[0]->{name};   }
sub verify { $_[0]->{verify}; }
sub tls    { $_[0]->{url} =~ "^https://"; }

#}}}
# query - make safe calls against this vault {{{
sub query {
	my $self = shift;
	my $opts = ref($_[0]) eq "HASH" ? shift : {};
	$opts->{env} ||= {};
	$opts->{env}{DEBUG} = "";                 # safe DEBUG is disruptive
	$opts->{env}{SAFE_TARGET} = $self->{url}; # set the safe target
	return run($opts, 'safe', @_);
}

# }}}
# get - get a key or all keys under for a given path {{{
sub get {
	my ($self, $path, $key) = @_;
	if (defined($key)) {
		my ($out,$rc) = $self->query('get', "$path:$key");
		return $out if $rc == 0;
		debug(
			"#R{[ERROR]} Could not read #C{%s:%s} from vault at #M{%s}",
			$path, $key,$self->{url}
		);
		return undef;
	}
	my ($out,$rc);
	eval {
		($out,$rc) = read_json_from($self->query('export', $path))->{$path};
	};
	if ($@) {
		debug(
			"#R{[ERROR]} Could not read all key/value pairs from #C{%s} in vault at #M{%s}:%s\nexit code: %s",
			$path,$self->{url},$@,$rc
		);
		return {};
	}
	return $out;
}

# }}}
# set - write a secret to the vault (prompts for value if not given) {{{
sub set {
	my ($self, $path, $key, $value) = @_;
	if (defined($value)) {
		my ($out,$rc) = $self->query('set', $path, "${key}=${value}");
		bail(
			"#R{[ERROR]} Could not write #C{%s:%s} to vault at #M{%s}:\n%s",
			$path, $key,$self->{url},$out
		) unless $rc == 0;
		return $value;
	} else {
		# Interactive - you must supply the prompt before hand
		my ($out,$rc) = $self->query({interactive => 1},'set', $path, $key);
		bail(
			"#R{[ERROR]} Could not write #C{%s:%s} to vault at #M{%s}",
			$path, $key,$self->{url}
		) unless $rc == 0;
		return $self->get($path,$key);
	}
}

# }}}
# has - return true if vault has given key {{{
sub has {
	my ($self, $path, $key) = @_;
	return $self->query({ passfail => 1 }, 'exists', defined($key) ? "$path:$key" : $path);
}

# }}}
# paths - return all paths found under the given prefixes (or all if no prefix given) {{{
sub paths {
	my ($self, @prefixes) = @_;

	# TODO: Once safe stops returning invalid pathts, the following will work:
	# return lines($self->query('paths', @prefixes));
	# instead, we have to do this less efficient routine
	return lines($self->query('paths')) unless scalar(@prefixes);

	my @all_paths=();
	for my $prefix (@prefixes) {
		my @paths = lines($self->query('paths', $prefix));
		if (scalar(@paths) == 1 && $paths[0] eq $prefix) {
			next unless $self->has($prefix);
		}
		push(@all_paths, @paths);
	}
	return @all_paths;
}

# }}}
# keys - return all path:key pairs under the given prefixes (or all if no prefix given) {{{
sub keys {
	my ($self, @prefixes) = @_;
	return lines($self->query('paths','--keys')) unless scalar(@prefixes);

	my @all_paths=();
	for my $prefix (@prefixes) {
		my @paths = lines($self->query('paths', '--keys', $prefix));
		next if (scalar(@paths) == 1 && $paths[0] eq $prefix);
		push(@all_paths, @paths);
	}
	return @all_paths;
}

# }}}
# ping - check if the vault is reachable and accessable {{{
sub ping {
	my ($self) = @_;
	return $self->has('secret/handshake');
}

# }}}
# status - returns status of vault: sealed, unreachable, invalid authentication or ok {{{
sub status {
	my $self = shift;

	return "unauthenticated" if $self->token eq "";
	my ($out,$rc) = $self->query({stderr => "&1"}, "vault", "status");
	if ($rc != 0) {
		$out =~ /exit status ([0-9])/;
		return "sealed" if $1 == 2;
		return "unreachable";
	}
	return "invalid authentication" unless $self->ping;
	return "ok"
}

# }}}
# env - return the environment variables needed to directly access the vault {{{
sub env {
	my $self = shift;
	unless (defined $self->{_env}) {
		$self->{_env} = read_json_from(
			run({
					stderr =>'/dev/null',
					env => {SAFE_TARGET => $self->{url} }
				},'safe', 'env', '--json')
		);
		$self->{_env}{VAULT_SKIP_VERIFY} ||= "";
		# die on missing VAULT_ADDR env?
	}
	return $self->{_env};
}

# }}}
# token - the authentication token for the active vault {{{
sub token {
	my $self = shift;
	return $self->env->{VAULT_TOKEN};
}

# }}}
# set_as_current - set this vault as the current Genesis vault {{{
sub set_as_current {
	my $self = shift;
	$ENV{GENESIS_TARGET_VAULT} = $self->url;
	$ENV{GENESIS_VERIFY_VAULT} = $self->verify ? "1" : "0";
	$current_vault = $self;
}

# }}}

## Private helper functions {{{

sub _target_is_url {
	my $target = lc(shift);
	return 0 unless $target =~ qr(^https?://([^:/]+)(?::([0-9]+))?$);
	return 0 if $2 && $2 > 65535;
	my @comp = split(/\./, $1);
	return 1 if scalar(@comp) == 4 && scalar(grep {$_ =~ /^[0-9]+$/ && $_ >=0 && $_ < 256} @comp) == 4;
	return 1 if scalar(grep {$_ !~ /[a-z0-9]([-_0-9a-z]*[a-z0-9])*/} @comp) == 0;
	return 0;
}

sub _get_targets {
	my $target = shift;
	unless (_target_is_url($target)) {
		my $target_vault = (grep {$_->{name} eq $target} Genesis::Vault->all)[0];
		return (undef) unless $target_vault;
		$target = $target_vault->{url};
	}
	my @names = map {$_->{name}} grep {$_->{url} eq $target} Genesis::Vault->all;
	return ($target, @names);
}

# }}}

# }}}

1;

=head1 NAME

Genesis::Vault

=head1 DESCRIPTION

This module provides utilities for interacting with a Vault through safe.

=head1 FUNCTIONS

=head2 target($url)

Returns a C<Genesis::Vault> object representing the vault at the given target.

This will raise an exception if this vault is not found locally
Reads the contents of C<$path>, interprets it as YAML, and parses it into a
Perl hashref structure.  This leverages C<spruce>, so it can only be used on
YAML documents with top-level maps.  In practice, this limitation is hardly
a problem.

=head2 Load($yaml)

Interprets its argument as a string of YAML, and parses it into a Perl
hashref structure.  This leverages C<spruce>, so it can only be used on
YAML documents with top-level maps.  In practice, this limitation is hardly
a problem.

=cut

# vim: fdm=marker:foldlevel=1:noet
