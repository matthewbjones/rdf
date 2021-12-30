require_relative 'spec_helper'
require 'rdf/spec/repository'

describe RDF::Repository do
  # @see lib/rdf/spec/repository.rb in rdf-spec
  it_behaves_like 'an RDF::Repository' do
    let(:repository) { RDF::Repository.new }
  end

  it { is_expected.not_to be_durable }

  it "maintains arbitrary options" do
    repository = RDF::Repository.new(foo: :bar)
    expect(repository.options).to have_key(:foo)
    expect(repository.options[:foo]).to eq :bar
  end

  context "A non-validatable repository" do
    # @see lib/rdf/spec/repository.rb in rdf-spec
    it_behaves_like 'an RDF::Repository' do
      let(:repository) { RDF::Repository.new(with_validity: false) }
    end
  end

  describe '#apply_changeset' do
    let(:changeset) { double('changeset', deletes: dels, inserts: ins) }

    let(:dels) { [] }
    let(:ins)  { [] }
    
    it 'applies atomically' do
      subject << existing_statement = RDF::Statement(:s, RDF.type, :o)
      dels << existing_statement
      ins << RDF::Statement(nil, nil, nil)

      expect do
        begin; subject.apply_changeset(changeset) rescue ArgumentError; end;
      end.not_to change { subject.statements }
    end
  end

  describe '#query_pattern' do
    before { subject.insert(*RDF::Spec.quads) }

    let(:graph_name) { subject.singleton_class::DEFAULT_GRAPH }

    it "returns statements from unnamed graphs with default graph_name" do
      pattern = RDF::Query::Pattern.new(nil, nil, nil, graph_name: graph_name)
      solutions = []
      subject.send(:query_pattern, pattern) {|s| solutions << s}
      
      unnamed_statements = subject.statements
      unnamed_statements.reject! {|st| st.name?}

      expect(solutions.size).to eq unnamed_statements.size
    end
  end

  it "remembers statement options" do
    subject << existing_statement = RDF::Statement(:s, RDF.type, :o, inferred: true)
    expect(subject).to have_statement(existing_statement)
    expect(subject.statements.first).to eq existing_statement
    expect(subject.statements.first).to be_inferred
  end

  it "performs coherent list updates" do
    # List updates require reading from the repository mid-transaction, which requires a SerializedTransaction
    repo = RDF::Repository.new
    lh = RDF::Node.new("o")
    repo << RDF::Statement.new(RDF::URI('s'), RDF::URI('p'), lh)
    expect(repo.count).to eq 1
    repo.transaction(mutable: true) do |tx|
      list = RDF::List.new(subject: lh, graph: tx, values: %w(a b c))
      expect(tx.count).to eq 7
      list[0, 2] = %(d)
      expect(tx.count).to eq 5
    end
    expect(repo.count).to eq 5
    
  end
end
