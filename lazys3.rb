#!/usr/bin/env ruby

# == Bucket Finder - Trawl Amazon S3 buckets for interesting files
#
# Each group of files on Amazon S3 have to be contained in a bucket and each bucket has to have a unique
# name across the system. This means that it is possible to bruteforce names, this script does this and more
#
# For more information on how this works see my blog post "Whats in Amazon's buckets?" at
#   http://www.digininja.org/blog/whats_in_amazons_buckets.php
#
# == Version
#
#  1.0 - Released
#  1.1 - Added log to file option
#
# == Usage
#
# bucket_finder.rb <wordlist>
#
# -l, --log-file <file name>:
#   filename to log output to
# -d, --download:
# 	download any public files found
# -r, --region:
# 	specify the start region
# -h, --help:
#	show help
#
# <wordlist>: the names to brute force
#
# Author:: Robin Wood (robin@digininja.org
# Copyright:: Copyright (c) Robin Wood 2011
# Licence:: Creative Commons Attribution-Share Alike Licence
#

require 'rexml/document'
require 'net/http'
require 'uri'
require 'getoptlong'
require 'fileutils'
require 'timeout'

class String
  def red;            "\e[31m#{self}\e[0m" end
  def black;          "\e[30m#{self}\e[0m" end
  def green;          "\e[32m#{self}\e[0m" end
  def brown;          "\e[33m#{self}\e[0m" end
  def blue;           "\e[34m#{self}\e[0m" end
  def magenta;        "\e[35m#{self}\e[0m" end
  def cyan;           "\e[36m#{self}\e[0m" end
  def gray;           "\e[37m#{self}\e[0m" end

  def bg_black;       "\e[40m#{self}\e[0m" end
  def bg_red;         "\e[41m#{self}\e[0m" end
  def bg_green;       "\e[42m#{self}\e[0m" end
  def bg_brown;       "\e[43m#{self}\e[0m" end
  def bg_blue;        "\e[44m#{self}\e[0m" end
  def bg_magenta;     "\e[45m#{self}\e[0m" end
  def bg_cyan;        "\e[46m#{self}\e[0m" end
  def bg_gray;        "\e[47m#{self}\e[0m" end

  def bold;           "\e[1m#{self}\e[22m" end
  def italic;         "\e[3m#{self}\e[23m" end
  def underline;      "\e[4m#{self}\e[24m" end
  def blink;          "\e[5m#{self}\e[25m" end
  def reverse_color;  "\e[7m#{self}\e[27m" end
end

# This is needed because the standard parse can't handle square brackets
# so this encodes them before parsing
module URI
  class << self

    def parse_with_safety(uri)
      parse_without_safety uri.gsub('[', '%5B').gsub(']', '%5D')
    end

    alias parse_without_safety parse
    alias parse parse_with_safety
  end
end

class Scanner
  def initialize(list,host,download,domain)
    @list = list
    @host = host
    @download = download
    @domain = domain
    @POOL_SIZE = 50
    @total = @list.length
  end

  def scan
     data = get_page @host, @domain
     doc = REXML::Document.new(data)
     if data != ''
       parse_results doc, @domain, @host, @download, 0
       jobs = Queue.new
     end
     @list.length.times{|i| jobs.push @list[i]}
     workers = (@POOL_SIZE).times.map do
     Thread.new do
       begin
	 while name = jobs.pop(true) rescue nil
	     url =  @domain+name
	     data = get_page @host, url
	   if data != ''
	     doc = REXML::Document.new(data)
             parse_results doc, url, @host, @download, 0
	   end
         end
       end
      end
     end
  workers.map(&:join)
  end

end

class Wordlist
  ENVIRONMENTS = %w(dev development stage s3 staging prod production test)
  PERMUTATIONS = %i(permutation_raw permutation_envs permutation_host)

  class << self
    def generate(common_prefix, prefix_wordlist)
      [].tap do |list|
        PERMUTATIONS.each do |permutation|
          list << send(permutation, common_prefix, prefix_wordlist)
        end
      end.flatten.uniq
    end

    def from_file(prefix, file)
      generate(prefix, IO.read(file).split("\n"))
    end

    def permutation_raw(common_prefix, _prefix_wordlist)
      common_prefix
    end

    def permutation_envs(common_prefix, prefix_wordlist)
      [].tap do |permutations|
        prefix_wordlist.each do |word|
          ENVIRONMENTS.each do |environment|
            ['%s-%s-%s', '%s-%s.%s', '%s-%s%s', '%s.%s-%s', '%s.%s.%s'].each do |bucket_format|
              permutations << format(bucket_format, common_prefix, word, environment)
            end
          end
        end
      end
    end

    def permutation_host(common_prefix, prefix_wordlist)
      [].tap do |permutations|
        prefix_wordlist.each do |word|
          ['%s.%s', '%s-%s', '%s%s'].each do |bucket_format|
            permutations << format(bucket_format, common_prefix, word)
            permutations << format(bucket_format, word, common_prefix)
          end
        end
      end
    end
  end
end

# Display the usage
def usage
	puts"lazys3-ng - based on the work by Robin Wood (robin@digininja.org) & namahsec

Usage: lazys3-ng -d domain [OPTION]
	--help, -h: show help
	--adquire, -a: adquire the public downloadable the files
	--domain, -d: domain to search by
	--log-file, -l: filename to log output to
	--region, -r: the region to use, options are:
					us - US Standard
					ie - Ireland
					nc - Northern California
					si - Singapore
					to - Tokyo
	-v: verbose

	--wordlist, -w: custom wordlist to use

"
	exit
end

def get_page host, page
	url = URI.parse(host)
	retries = [3, 3, 3, 3, 3]
	begin
		res = Net::HTTP.start(url.host, url.port) {|http|
			http.get("/" + page)
		}
	rescue Timeout::Error
		puts "Timeout requesting page: " + url.host
		@logging.puts "Timeout requesting page: " + url.host unless @logging.nil?
		return ''
	rescue => e
		puts "Error requesting page: " + url.host + "/" + page + " " + e.to_s + ". Retrying..."
		if delay = retries.shift # will be nil if the list is empty
                  sleep delay
		  retry # backs up to just after the "begin"
		else
		  @logging.puts "Error requesting page: " + url.host + "/" + page + " " + e.to_s unless @logging.nil?
		  return ''
		end
	end
	return res.body
end

def parse_results doc, bucket_name, host, download, depth = 0
	tabs = ''
	depth.times {
		tabs += "\t"
	}

	if !doc.elements['ListBucketResult'].nil?
		puts tabs + "Bucket Found: ".green + bucket_name.green + " ( ".green + host.green + "/".green + bucket_name.green + " )".green
		@logging.puts tabs + "Bucket Found: ".green + bucket_name.green + " ( ".green + host.green + "/".green + bucket_name.green + " )".green unless @logging.nil?

	elsif doc.elements['Error']
		err = doc.elements['Error']
                if !err.elements['Code'].nil?
			case err.elements['Code'].text
				when "NoSuchKey"
					print tabs + "The specified key does not exist: " + bucket_name + "\n"
					@logging.puts tabs + "The specified key does not exist: " + bucket_name unless @logging.nil?
				when "AccessDenied"
					print tabs + "Bucket found but access denied: ".brown + bucket_name.brown + "\n"
					@logging.puts tabs + "Bucket found but access denied: ".brown + bucket_name.brown unless @logging.nil?
				when "NoSuchBucket"
					#print tabs + "Bucket does not exist: ".red + bucket_name.red + "\n"
					@logging.puts tabs + "Bucket does not exist: " + bucket_name unless @logging.nil?
				when "PermanentRedirect"
					if !err.elements['Endpoint'].nil?
						print tabs + "Bucket ".blue + bucket_name.blue + " redirects to: ".blue + err.elements['Endpoint'].text.blue + "\n"
						@logging.puts tabs + "Bucket ".blue + bucket_name.blue + " redirects to: ".blue + err.elements['Endpoint'].text.blue unless @logging.nil?

						data = get_page 'http://' + err.elements['Endpoint'].text, ''
						if data != ''
							doc = REXML::Document.new(data)
							parse_results doc, bucket_name, err.elements['Endpoint'].text, download, depth + 1
						end
					else
						print tabs + "Redirect found but can't find where to: " + bucket_name + "\n"
						@logging.puts tabs + "Redirect found but can't find where to: " + bucket_name unless @logging.nil?
					end
			end
		end
	else
		print tabs + ' No data returned' + "\n"
		@logging.puts tabs + ' No data returned' unless @logging.nil?
	end
end

opts = GetoptLong.new(
	[ '--domain', '-d', GetoptLong::REQUIRED_ARGUMENT ],
	[ '--help', '-h', GetoptLong::NO_ARGUMENT ],
	[ '--region', '-r', GetoptLong::REQUIRED_ARGUMENT ],
	[ '--log-file', '-l', GetoptLong::REQUIRED_ARGUMENT ],
	[ '--download', '-a', GetoptLong::NO_ARGUMENT ],
	[ "-v" , GetoptLong::NO_ARGUMENT ]
)

# setup the defaults
download = false
verbose = false
full = false
region = "us"
domain = ""
@logging = nil

begin
	opts.each do |opt, arg|
		case opt
			when '--help'
				usage
			when '--domain'
				domain = arg
			when '--download'
				download = true
			when '--full'
				full = true
			when "--log-file"
				begin
					@logging = File.open(arg, "w")
				rescue
					puts "Could not open the logging file\n"
					exit
				end
			when "--region"
				region = arg
		end
	end
rescue
	usage
end

filename = ARGV.shift

case region
	when "ie"
		host = ('http://s3-eu-west-1.amazonaws.com')
	when "nc"
		host = ('http://s3-us-west-1.amazonaws.com')
	when "us"
		host = ('http://s3.amazonaws.com')
	when "si"
		host = ('http://s3-ap-southeast-1.amazonaws.com')
	when "to"
		host = ('http://s3-ap-northeast-1.amazonaws.com')
	else
		puts "Unknown region specified"
		puts
		usage
end

if domain.to_s.empty?
	puts "[+] Domain (-d/--domain) is required!"
	puts
	usage
end

wordlist = Wordlist.from_file(ARGV[0], './dict/common_bucket_prefixes_full.txt')
start = Time.now

puts "Generated wordlist from file, #{wordlist.length} items..."
puts "Start time: " + start.to_s

Scanner.new(wordlist,host,download,domain).scan

puts "Finish time: " + Time.now.to_s
puts "Total time: " + (Time.now - start).to_s

@logging.close unless @logging.nil?
