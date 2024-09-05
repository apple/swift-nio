#!/usr/bin/env ruby
##===----------------------------------------------------------------------===##
##
## This source file is part of the SwiftNIO open source project
##
## Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of SwiftNIO project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##
require 'optparse'

METRIC="min" # used for comparison

module Enumerable
  def sum
    return self.inject(0){|accum, i| accum + i }
  end

  def mean
    return self.sum / self.length.to_f
  end

  def sample_variance
    m = self.mean
    sum = self.inject(0){|accum, i| accum + (i - m) ** 2 }
    return sum / (self.length - 1).to_f
  end

  def standard_deviation
    return Math.sqrt(self.sample_variance)
  end
end

def parse_results(file)
  results = {}
  File.open(file, "r") do |f|
    f.each_line do |line|
      parts = line.split(':').collect(&:strip)
      throw "invalid data format" unless parts.length == 3
      key = parts[1]
      values = parts[2].split(',').collect(&:strip).map(&:to_f)
      results[key] = {}
      results[key]["values"] = values
      results[key]["max"] = values.max
      results[key]["min"] = values.min
      results[key]["mean"] = values.mean
      results[key]["std"] = values.standard_deviation
    end
  end
  results
end

def compare_results(current, previous)
  results = {}
  current.keys.each do |key|
    results[key] = {}
    results[key]["previous"] = previous[key] || { ::METRIC => "n/a" }
    results[key]["current"] = current[key]
    if previous[key]
      current_value = current[key][::METRIC]
      previous_value = previous[key][::METRIC]
      delta = current_value - previous_value
      results[key]["delta"] = delta
      results[key]["winner"] = current_value <= previous_value ? "current" : "previous"
      results[key]["diff"] = (delta / previous_value * 100).to_i
    else
      results[key]["winner"] = "n/a"
      results[key]["diff"] = "n/a"
    end
  end
  results
end

def print_results_markdown(results)
  columns = ["min", "max", "mean", "std"]
  puts "| name | #{columns.join(" | ")} |"
  puts "|#{Array.new(columns.size+1, '---').join("|")}|"
  results.keys.each do |key|
    print "| `#{key}`"
    columns.each do |column|
      print " | #{results[key][column]}"
    end
    puts " |\n"
  end
end

def print_results_html(results)
  columns = ["min", "max", "mean", "std"]
  puts "<table border=\"1\">"
  puts "<tr><td>name</td><td>#{columns.join("</td><td>")}</td></tr>"
  results.keys.each do |key|
    puts "<tr>"
    puts "<td>#{key}</td>"
    columns.each do |column|
      puts "<td>#{results[key][column]}</td>"
    end
    puts "</tr>"
  end
  puts "</table>"
end

def print_results_csv(results)
  puts results.keys.join(",")
  puts results.keys.map{ |key| results[key][::METRIC] }.join(",")
end

def print_comparison_markdown(results)
  puts "| name | current | previous | winner | diff |"
  puts "|#{Array.new(5, '---').join("|")}|"
  results.keys.each do |key|
    puts "| `#{key}` | #{results[key]["current"][::METRIC]} | #{results[key]["previous"][::METRIC]} | #{results[key]["winner"]} | #{results[key]["diff"]}% |"
  end
end

def print_comparison_html(results)
  puts "<table border=\"1\">"
  puts "  <tr>
    <td>name</td>
    <td>current</td>
    <td>previous</td>
    <td>winner</td>
    <td>diff</td>
  </tr>"
  results.keys.each do |key|
    puts "  <tr>
    <td>#{key}</td>
    <td>#{results[key]["current"][::METRIC]}</td>
    <td>#{results[key]["previous"][::METRIC]}</td>
    <td>#{results[key]["winner"]}</td>
    <td>#{results[key]["diff"]}%</td>
  </tr>"
  end
  puts "</table>"
end


ARGV << '-h' if ARGV.empty?

options = {}
OptionParser.new do |opt|
  opt.on('-f', '--file file', 'file to process') { |o| options[:file] = o }
  opt.on('-p', '--previous previous', 'previous file to process') { |o| options[:previous] = o }
  opt.on('-o', '--output output', 'output format') { |o| options[:output] = o }
  opt.on_tail("-h", "--help", "show this message") do
    puts opt
  end
end.parse!

if options.has_key?(:file) && options.has_key?(:previous)
  current = parse_results(options[:file])
  previous = parse_results(options[:previous])
  results = compare_results(current, previous)

  case options[:output]
  when "html"
    print_comparison_html(results)
  when "markdown", nil
    print_comparison_markdown(results)
  else
    throw "invalid output format #{options[:output]}"
  end

elsif options.has_key?(:file)
  results = parse_results(options[:file])
  case options[:output]
  when "csv"
    print_results_csv(results)
  when "html", nil
    print_results_html(results)
  when "markdown", nil
    print_results_markdown(results)
  else
    throw "invalid output format #{options[:output]}"
  end

else
  throw "invalid arguemnts"
end
