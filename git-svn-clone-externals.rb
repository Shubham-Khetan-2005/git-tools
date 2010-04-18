#!/usr/bin/ruby -w
#
# Recursively clone svn:externals in a git-svn sandbox.
#
# Written by Marc Liyanage <http://www.entropy.ch>
#
# See http://github.com/liyanage/git-tools
#

require 'fileutils'

class ExternalsProcessor

def initialize(options = {})
	@parent = options[:parent];
	@externals_url = options[:externals_url];
end


def run
	update_current_dir
	process_svn_ignore_for_current_dir

	read_externals.each do |dir, url|
		raise "Error: svn:externals cycle detected: '#{url}'" if known_url?(url)
		puts "[#{dir}] updating SVN external: #{dir}"
		
		raise "Error: Unable to find or mkdir '#{dir}'" unless File.exist?(dir) || FileUtils.mkpath(dir)
		raise "Error: Expected '#{dir}' to be a directory" unless File.directory?(dir)
		
		Dir.chdir(dir) {self.class.new(:parent => self, :externals_url => url).run}
		update_exclude_file_with_paths(dir)
	end

	return 0
end


def update_current_dir
	wd = Dir.getwd
	contents = Dir.entries('.').reject {|x| x =~ /^(?:\.+|\.DS_Store)$/}

	if contents.count == 0
		# first-time clone
		raise "Error: Missing externals URL for '#{wd}'" unless @externals_url
		shell("git svn clone #@externals_url .")
	elsif contents.count == 1 && contents[0] == '.git'
		# interrupted clone, restart with fetch
		shell('git svn fetch')
	else
		# regular update, rebase to SVN head

		# Check that we're on the right branch
		shell('git status')[0] =~ /On branch (\S+)/;
		raise "Error: Unable to determine Git branch in '#{wd}' using 'git status'" unless $~
		branch = $~[1]
 		raise "Error: Git branch is '#{branch}', should be 'master' in '#{wd}'\n" unless branch == 'master'

		# Check that there are no uncommitted changes in the working copy that would trip up git's svn rebase
		dirty = shell('git status --porcelain').reject {|x| x =~ /^\?\?/}
		raise "Error: Can't run svn rebase with dirty files in '#{wd}':\n#{dirty.map {|x| x + "\n"}}" unless dirty.empty?

		# Check that the externals definition URL hasn't changed
		url = svn_url_for_current_dir
		if @externals_url && @externals_url != url
			raise "Error: The svn:externals URL for '#{wd}' is defined as\n\n  #@externals_url\n\nbut the existing Git working copy in that directory is configured as\n\n  #{url}\n\nThe externals definition might have changed since the working copy was created. Remove the '#{wd}' directory and re-run this script to check out a new version from the new URL.\n";
		end

		# All sanity checks OK, perform the update
		shell_echo('git svn rebase')
	end

end


def read_externals
	externals = shell('git svn show-externals').reject {|x| x =~ %r%^\s*/?\s*#%}
	versioned_externals = externals.grep(/-r\d+\b/i)
	if !versioned_externals.empty?
		raise "Error: Found external(s) pegged to fixed revision: '#{versioned_externals.join ', '}' in '#{Dir.getwd}', don't know how to handle this."
	end
	return externals.grep(%r%^/(\S+)\s+(\S+)%) {$~[1,2]}
end


def process_svn_ignore_for_current_dir
	svn_ignored = shell('git svn show-ignore').reject {|x| x =~ %r%^\s*/?\s*#%}.grep(%r%^/(\S+)%) {$~[1]}
	update_exclude_file_with_paths(svn_ignored) unless svn_ignored.empty?
end


def update_exclude_file_with_paths(excluded_paths)
	excludefile_path = '.git/info/exclude';
	exclude_file = File.open(excludefile_path) if File.exist?(excludefile_path)
	exclude_lines = exclude_file ? exclude_file.readlines.map {|x| x.chomp} : []

	new_exclude_lines = []
	excluded_paths.each do |path|
		new_exclude_lines.push(path) unless (exclude_lines | new_exclude_lines).include?(path)
	end

	return if new_exclude_lines.empty?

	puts "Updating Git exclude list '#{Dir.getwd}/#{excludefile_path}' with new items: #{new_exclude_lines.join(" ")}\n";
	File.open(excludefile_path, 'w') << (exclude_lines + new_exclude_lines).map {|x| x + "\n"}
end


def svn_info_for_current_dir
	svn_info = {};
	shell('git svn info').map {|x| x.split(': ')}.each {|k, v| svn_info[k] = v}
	return svn_info
end


def svn_url_for_current_dir
	url = svn_info_for_current_dir['URL']
	raise "Unable to determine SVN URL for '#{Dir.getwd}'" unless url;
	return url
end


def known_url?(url)
	return url == svn_url_for_current_dir || (@parent && @parent.known_url?(url))
end


def shell(cmd)
	list = %x(#{cmd}).split("\n")
	status = $? >> 8
	raise "Non-zero exit status #{status} for command #{cmd}" if status != 0
	return list
end


def shell_echo(cmd)
	list = %x(#{cmd} | tee /dev/stderr).split("\n")
	status = $? >> 8
	raise "Non-zero exit status #{status} for command #{cmd}" if status != 0
	return list
end

end


# ----------------------

ENV['PATH'] = "/opt/local/bin:#{ENV['PATH']}";
exit ExternalsProcessor.new.run