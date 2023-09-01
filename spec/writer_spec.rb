# -*- encoding: utf-8 -*-
require_relative 'spec_helper'
require 'rdf/ntriples'

describe RDF::Writer do
  describe ".for" do
    [
      :ntriples,
      'etc/doap.nt',
      {file_name:      'etc/doap.nt'},
      {file_extension: 'nt'},
      {content_type:   'application/n-triples'},
    ].each do |arg|
      it "discovers with #{arg.inspect}" do
        expect(RDF::Writer.for(arg)).to eq RDF::NTriples::Writer
      end
    end
  end

  describe ".accept?" do
    it "returns true by default" do
      expect(RDF::Writer.accept?({})).to be_truthy
    end
    it "returns block, if given" do
      expect(RDF::Writer.accept?({}) {false}).to be_falsy
    end
  end
end
