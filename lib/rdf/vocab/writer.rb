require 'rdf'
require 'rdf/vocabulary'
require 'cgi'

module RDF
  ##
  # Vocabulary format specification. This can be used to generate a Ruby class definition from a loaded vocabulary.
  #
  # Definitions can include recursive term definitions, when the value of a property is a blank-node term. They can also include list definitions, to provide a reasonable way to represent `owl:unionOf`-type relationships.
  #
  # @example a simple term definition
  #     property :comment,
  #       comment: %(A description of the subject resource.).freeze,
  #       domain: "rdfs:Resource".freeze,
  #       label: "comment".freeze,
  #       range: "rdfs:Literal".freeze,
  #       isDefinedBy: %(rdfs:).freeze,
  #       type: "rdf:Property".freeze
  #
  # @example an embedded skos:Concept
  #     term :ad,
  #       exactMatch: [term(
  #           type: "skos:Concept".freeze,
  #           inScheme: "country:iso3166-1-alpha-2".freeze,
  #           notation: %(ad).freeze
  #         ), term(
  #           type: "skos:Concept".freeze,
  #           inScheme: "country:iso3166-1-alpha-3".freeze,
  #           notation: %(and).freeze
  #         )],
  #       "foaf:name": "Andorra".freeze,
  #       isDefinedBy: "country:".freeze,
  #       type: "http://sweet.jpl.nasa.gov/2.3/humanJurisdiction.owl#Country".freeze
  #
  # @example owl:unionOf
  #     property :duration,
  #       comment: %(The duration of a track or a signal in ms).freeze,
  #       domain: term(
  #           "owl:unionOf": list("mo:Track".freeze, "mo:Signal".freeze),
  #           type: "owl:Class".freeze
  #         ),
  #       isDefinedBy: "mo:".freeze,
  #       "mo:level": "1".freeze,
  #       range: "xsd:float".freeze,
  #       type: "owl:DatatypeProperty".freeze,
  #       "vs:term_status": "testing".freeze
  class Vocabulary
    class Format < RDF::Format
      content_encoding 'utf-8'
      writer { RDF::Vocabulary::Writer }
    end

    class Writer < RDF::Writer
      include RDF::Util::Logger
      format RDF::Vocabulary::Format

      attr_accessor :class_name, :module_name

      def self.options
        [
          RDF::CLI::Option.new(
            symbol: :class_name,
            datatype: String,
            control: :text,
            on: ["--class-name NAME"],
            use: :required,
            description: "Name of created Ruby class (vocabulary format)."),
          RDF::CLI::Option.new(
            symbol: :extra,
            datatype: String,
            control: :none,
            on: ["--extra URIEncodedJSON"],
            description: "URI Encoded JSON representation of extra data"
          ) do |arg|
            ::JSON.parse(::CGI.unescape(arg)).inject({}) do |m1, (term, defs)|
              d1 = defs.inject({}) {|m, (k,v)| m.merge(k.to_sym => v)}
              m1.merge(term.to_sym => d1)
            end
          end,
          RDF::CLI::Option.new(
            symbol: :module_name,
            datatype: String,
            control: :text,
            on: ["--module-name NAME"],
            description: "Name of Ruby module containing class-name (vocabulary format)."),
          RDF::CLI::Option.new(
            symbol: :noDoc,
            datatype: TrueClass,
            control: :checkbox,
            on: ["--noDoc"],
            description: "Do not output Yard documentation."),
          RDF::CLI::Option.new(
            symbol: :strict,
            datatype: TrueClass,
            control: :checkbox,
            on: ["--strict"],
            description: "Make strict vocabulary"
          ) {true},
        ]
      end

      ##
      # Initializes the writer.
      #
      # @param  [IO, File] output
      #   the output stream
      # @param [RDF::URI]  base_uri
      #   URI of this vocabulary
      # @param  [Hash{Symbol => Object}] options = ({})
      #   any additional options. See {RDF::Writer#initialize}
      # @option options [String]  :class_name
      #   Class name for this vocabulary
      # @option options [String]  :module_name ("RDF")
      #   Module name for this vocabulary
      # @option options [Hash] extra
      #   Extra properties to add to the output (programatic only)
      # @option options [String] patch
      #   An LD Patch to run against the graph before writing
      # @option options [Boolean] strict (false)
      #   Create an RDF::StrictVocabulary instead of an RDF::Vocabulary
      # @yield  [writer] `self`
      # @yieldparam  [RDF::Writer] writer
      # @yieldreturn [void]
      def initialize(output = $stdout, base_uri:, **options, &block)
        @graph = RDF::Repository.new
        options.merge(base_uri: base_uri)
        super
      end

      def write_triple(subject, predicate, object)
        @graph << RDF::Statement(subject, predicate, object)
      end

      # Generate vocabulary
      #
      def write_epilogue
        class_name = options[:class_name]
        module_name = options.fetch(:module_name, "RDF")
        source = options.fetch(:location, base_uri)
        strict = options.fetch(:strict, false)

        # Passing a graph for the location causes it to serialize the written triples.
        vocab = RDF::Vocabulary.from_graph(@graph,
                                           url: base_uri,
                                           class_name: class_name,
                                           extra: options[:extra])

        @output.print %(# -*- encoding: utf-8 -*-
          # frozen_string_literal: true
          # This file generated automatically using rdf vocabulary format from #{source}
          require 'rdf'
          module #{module_name}
          ).gsub(/^          /, '')

          @output.print %(  # @!parse
            #   # Vocabulary for <#{base_uri}>
            #   #
          ).gsub(/^          /, '') unless @options[:noDoc]

        if vocab.ontology && !@options[:noDoc]
          ont_doc = []
          %i(
            http://purl.org/dc/terms/title
            http://purl.org/dc/elements/1.1/title
            label
            comment
            http://purl.org/dc/terms/description
            http://purl.org/dc/elements/1.1/description
          ).each do |attr|
            next unless vocab.ontology.attributes[attr]
            Array(vocab.ontology.attributes[attr]).each do |v|
              ont_doc << "  #   # " + v.to_s.gsub(/\n/, ' ')
            end
          end
          @output.puts ont_doc.join("\n  #   #\n") unless ont_doc.empty?
          # Version Info
          Array(vocab.ontology.attributes[:"owl:versionInfo"]).each do |vers|
            @output.puts "  #   # @version #{vers}"
          end
          # See Also
          Array(vocab.ontology.attributes[:"rdfs:seeAlso"]).each do |see|
            @output.puts "  #   # @see #{see}"
          end
        end
        @output.puts %(  #   class #{class_name} < RDF::#{"Strict" if strict}Vocabulary) unless @options[:noDoc]

        # Split nodes into Class/Property/Datatype/Other
        term_nodes = {
          ontology: {},
          class: {},
          property: {},
          datatype: {},
          other: {}
        }

        # Generate Ontology first
        if vocab.ontology
          term_nodes[:ontology][vocab.ontology.to_s] = vocab.ontology.attributes
        end

        vocab.each.to_a.sort.each do |term|
          name = term.to_s[base_uri.length..-1].to_sym
          next if name.to_s.empty?  # Ontology serialized separately
          kind = begin
            case term.type.to_s
            when /Class/    then :class
            when /Property/ then :property
            when /Datatype/ then :datatype
            else                 :other
            end
          rescue KeyError
            # This can try to resolve referenced terms against the previous version of this vocabulary, which may be strict, and fail if the referenced term hasn't been created yet.
            :other
          end
          term_nodes[kind][name] = term.attributes
        end

        # Yard attribute information for terms
        term_nodes.each do |tt, ttv|
          next if tt == :ontology
          ttv.each do |name, attributes|
            # Only document terms that can be accessed like a Ruby attribute
            next unless name.to_s.match?(/^[_[:alpha:]](?:\w*)[!?=]?$/)
            @output.puts(Array(attributes[:comment]).map do |comment|
              "  #     # #{comment.to_s.gsub(/\n/, ' ')}"
            end.join("\n  #     #\n")) if attributes[:comment]
            @output.puts "  #     # @return [RDF::Vocabulary::Term]"
            @output.puts "  #     attr_reader :#{name}"
            @output.puts "  #"
          end
        end unless @options[:noDoc]

        # End of yard preamble
        @output.puts "  #   end" unless @options[:noDoc]
        @output.puts %(  #{class_name} = Class.new(RDF::#{"Strict" if strict}Vocabulary("#{base_uri}")) do)

        # Output term definitions
        {
          ontology: "Ontology definition",
          class: "Class definitions",
          property: "Property definitions",
          datatype: "Datatype definitions",
          other: "Extra definitions"
        }.each do |tt, comment|
          next if term_nodes[tt].empty?
          @output.puts "\n    # #{comment}"
          term_nodes[tt].each {|name, attributes| from_node name, attributes, tt}
        end

        # Query the vocabulary to extract property and class definitions
        @output.puts "  end\nend"
      end

    private
      ##
      # Turn a node definition into a property/term expression
      def from_node(name, attributes, term_type)
        op = case term_type
        when :property then "property"
        when :ontology then "ontology"
        else                "term"
        end

        components = ["    #{op} #{name.to_sym.inspect}"]
        attributes.keys.sort_by(&:to_s).map(&:to_sym).each do |key|
          value = Array(attributes[key])
          component = key.inspect.start_with?(':"') ? "#{key.to_s.inspect}: " : "#{key}: "
          value = value.first if value.length == 1
          component << if value.is_a?(Array)
            '[' + value.map {|v| serialize_value(v, key, indent: "      ")}.sort.join(", ") + "]"
          else
            serialize_value(value, key, indent: "      ")
          end
          components << component
        end
        @output.puts components.join(",\n      ")
      end

      def serialize_value(value, key, indent: "")
        if value.is_a?(Literal) && %w(: comment definition notation note editorialNote).include?(key.to_s)
          "#{value.to_s.inspect}.freeze"
        elsif value.is_a?(RDF::URI)
          "#{value.to_s.inspect}.freeze"
        elsif value.is_a?(RDF::Vocabulary::Term)
          value.to_ruby(indent: indent + "  ")
        elsif value.is_a?(RDF::Term)
          "#{value.to_s.inspect}.freeze"
        elsif value.is_a?(RDF::List)
          list_elements = value.map do |u|
            if u.uri?
              "#{u.to_s.inspect}.freeze"
            elsif u.respond_to?(:to_ruby)
              u.to_ruby(indent: indent + "  ")
            else
              "#{u.to_s.inspect}.freeze"
            end
          end
          "list(#{list_elements.join(', ')})"
        else
          "#{value.inspect}.freeze"
        end
      end
    end
  end
end
