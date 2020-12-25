# coding: utf-8
module RDF
  ##
  # An RDF list.
  #
  # @example Constructing a new list
  #   RDF::List[1, 2, 3]
  #
  # @since 0.2.3
  class RDF::List
    include RDF::Enumerable
    include RDF::Value
    include Comparable

    ##
    # Constructs a new list from the given `values`.
    #
    # The list will be identified by a new autogenerated blank node, and
    # backed by an initially empty in-memory graph.
    #
    # @example
    #     RDF::List[]
    #     RDF::List[*(1..10)]
    #     RDF::List[1, 2, 3]
    #     RDF::List["foo", "bar"]
    #     RDF::List["a", 1, "b", 2, "c", 3]
    #
    # @param  [Array<RDF::Term>] values
    # @return [RDF::List]
    def self.[](*values)
      self.new(subject: nil, graph: nil, values: values)
    end

    ##
    # Initializes a newly-constructed list.
    #
    # Instantiates a new list based at `subject`, which **should** be an RDF::Node. List may be initialized using passed `values`.
    #
    # If a `values` initializer is set with an empty list, `subject`
    # will be used as the first element in the list. Otherwise,
    # if the list is not empty, `subject` identifies the first element
    # of the list to which `values` are prepended yielding a new `subject`.
    # Otherwise, if there are no initial `values`, and `subject` does
    # not identify an existing list in `graph`, the list remains
    # identified by `subject`, but will be invalid.
    #
    # @example add constructed list to existing graph
    #     l = RDF::List(values: (1, 2, 3))
    #     g = RDF::Graph.new << l
    #     g.count # => l.count
    #
    # @example use a transaction for block initialization
    #     l = RDF::List(graph: graph, wrap_transaction: true) do |list|
    #       list << RDF::Literal(1)
    #       # list.graph.rollback will rollback all list changes within this block.
    #     end
    #     list.count #=> 1
    #
    # @param  [RDF::Resource]         subject (RDF.nil)
    #   Subject should be an {RDF::Node}, not a {RDF::URI}. A list with an IRI head will not validate, but is commonly used to detect if a list is valid.
    # @param  [RDF::Graph]        graph (RDF::Graph.new)
    # @param  [Array<RDF::Term>]  values
    #   Any values which are not terms are coerced to `RDF::Literal`.
    # @param [Boolean] wrap_transaction (false)
    #   Wraps the callback in a transaction, and replaces the graph with that transaction for the duraction of the callback. This has the effect of allowing any list changes to be made atomically, or rolled back.
    # @yield  [list]
    # @yieldparam [RDF::List] list
    def initialize(subject: nil, graph: nil, values: nil, wrap_transaction: false, &block)
      @subject = subject || RDF.nil
      @graph   = graph   || RDF::Graph.new
      is_empty = @graph.query({subject: subject, predicate: RDF.first}).empty?

      if subject && is_empty
        # An empty list with explicit subject and value initializers
        @subject = RDF.nil
        first, *values = Array(values)
        if first || values.length > 0
          # Intantiate the list from values, and insert the first value using subject.
          values.reverse_each {|value| self.unshift(value)}
          @graph.insert RDF::Statement(subject, RDF.first, first || RDF.nil)
          @graph.insert RDF::Statement(subject, RDF.rest, @subject)
        end
        @subject = subject
      else
        # Otherwise, prepend any values, which resets @subject
        Array(values).reverse_each {|value| self.unshift(value)}
      end

      if block_given?
        if wrap_transaction
          old_graph = @graph
          begin
            Transaction.begin(@graph, graph_name: @graph.graph_name, mutable: @graph.mutable?) do |trans|
              @graph = trans
              case block.arity
                when 1 then block.call(self)
                else instance_eval(&block)
              end
              trans.execute if trans.mutated?
            end
          ensure
            @graph = old_graph
          end
        else
          case block.arity
            when 1 then block.call(self)
            else instance_eval(&block)
          end
        end
      end
    end

    UNSET = Object.new.freeze # @private

    # The canonical empty list.
    NIL = RDF::List.new(subject: RDF.nil).freeze

    ##
    # Is this a {RDF::List}?
    #
    # @return [Boolean]
    def list?
      true
    end

    ##
    # Validate the list ensuring that
    # * each node is referenced exactly once (except for the head, which may have no reference)
    # * rdf:rest values are all BNodes are nil
    # * each subject has exactly one value for `rdf:first` and
    #   `rdf:rest`.
    # * The value of `rdf:rest` must be either a BNode or `rdf:nil`.
    # * only the list head may have any other properties
    # @return [Boolean]
    def valid?
      li = subject
      list_nodes = []
      while li != RDF.nil do
        return false if list_nodes.include?(li)
        list_nodes << li
        rest = nil
        firsts = rests = 0
        @graph.query({subject: li}) do |st|
          return false unless st.subject.node?
          case st.predicate
          when RDF.first
            firsts += 1
          when RDF.rest
            rest = st.object
            return false unless rest.node? || rest == RDF.nil
            rests += 1
          when RDF.type
          else
            # It may have no other properties
            return false unless li == subject
          end
        end
        return false unless firsts == 1 && rests == 1
        li = rest
      end

      # All elements other than the head must be referenced exactly once
      return list_nodes.all? do |li|
        refs = @graph.query({object: li}).count
        case refs
        when 0 then li == subject
        when 1 then true
        else        false
        end
      end
    end

    # @!attribute [r] subject
    # @return [RDF::Resource] the subject term of this list.
    attr_reader :subject

    # @!attribute [r] graph
    # @return [RDF::Graph] the underlying graph storing the statements that constitute this list
    attr_reader :graph

    ##
    # @see RDF::Value#==
    def ==(other)
      return false if other.is_a?(RDF::Value) && !other.list?
      super
    end

    ##
    # Returns the set intersection of this list and `other`.
    #
    # The resulting list contains the elements common to both lists, with no
    # duplicates.
    #
    # @example
    #   RDF::List[1, 2] & RDF::List[1, 2]       #=> RDF::List[1, 2]
    #   RDF::List[1, 2] & RDF::List[2, 3]       #=> RDF::List[2]
    #   RDF::List[1, 2] & RDF::List[3, 4]       #=> RDF::List[]
    #
    # @param  [RDF::List] other
    # @return [RDF::List]
    # @see    http://ruby-doc.org/core-2.2.2/Array.html#method-i-26
    def &(other)
      self.class.new(values: (to_a & other.to_a))
    end

    ##
    # Returns the set union of this list and `other`.
    #
    # The resulting list contains the elements from both lists, with no
    # duplicates.
    #
    # @example
    #   RDF::List[1, 2] | RDF::List[1, 2]       #=> RDF::List[1, 2]
    #   RDF::List[1, 2] | RDF::List[2, 3]       #=> RDF::List[1, 2, 3]
    #   RDF::List[1, 2] | RDF::List[3, 4]       #=> RDF::List[1, 2, 3, 4]
    #
    # @param  [RDF::List] other
    # @return [RDF::List]
    # @see    http://ruby-doc.org/core-2.2.2/Array.html#method-i-7C
    def |(other)
      self.class.new(values: (to_a | other.to_a))
    end

    ##
    # Returns the concatenation of this list and `other`.
    #
    # @example
    #   RDF::List[1, 2] + RDF::List[3, 4]       #=> RDF::List[1, 2, 3, 4]
    #
    # @param  [RDF::List] other
    # @return [RDF::List]
    # @see    http://ruby-doc.org/core-2.2.2/Array.html#method-i-2B
    def +(other)
      self.class.new(values: (to_a + other.to_a))
    end

    ##
    # Returns the difference between this list and `other`, removing any
    # elements that appear in both lists.
    #
    # @example
    #   RDF::List[1, 2, 2, 3] - RDF::List[2]    #=> RDF::List[1, 3]
    #
    # @param  [RDF::List] other
    # @return [RDF::List]
    # @see    http://ruby-doc.org/core-2.2.2/Array.html#method-i-2D
    def -(other)
      self.class.new(values: (to_a - other.to_a))
    end

    ##
    # Returns either a repeated list or a string concatenation of the
    # elements in this list.
    #
    # @overload *(times)
    #   Returns a new list built of `times` repetitions of this list.
    #
    #   @example
    #     RDF::List[1, 2, 3] * 2                #=> RDF::List[1, 2, 3, 1, 2, 3]
    #
    #   @param  [Integer] times
    #   @return [RDF::List]
    #
    # @overload *(sep)
    #   Returns the string concatenation of the elements in this list
    #   separated by `sep`. Equivalent to `self.join(sep)`.
    #
    #   @example
    #     RDF::List[1, 2, 3] * ","              #=> "1,2,3"
    #
    #   @param  [String, #to_s] sep
    #   @return [RDF::List]
    #
    # @return [RDF::List]
    # @see    http://ruby-doc.org/core-2.2.2/Array.html#method-i-2A
    def *(int_or_str)
      case int_or_str
        when Integer then self.class.new(values: (to_a * int_or_str))
        else join(int_or_str.to_s)
      end
    end

    ##
    # Returns the element at `index`.
    #
    # @example
    #   RDF::List[1, 2, 3][0]                   #=> RDF::Literal(1)
    #
    # @param  [Integer] index
    # @return [RDF::Term]
    # @see    http://ruby-doc.org/core-2.2.2/Array.html#method-i-5B-5D
    def [](index)
      at(index)
    end

    ##
    # Element Assignment — Sets the element at `index`, or replaces a subarray from the `start` index for `length` elements, or replaces a subarray specified by the `range` of indices.
    #
    # If indices are greater than the current capacity of the array, the array grows automatically. Elements are inserted into the array at `start` if length is zero.
    #
    # Negative indices will count backward from the end of the array. For `start` and `range` cases the starting index is just before an element.
    #
    # An `IndexError` is raised if a negative index points past the beginning of the array.
    #
    # (see #unshift).
    #
    # @example
    #     a = RDF::List.new
    #     a[4] = "4";                 #=> [rdf:nil, rdf:nil, rdf:nil, rdf:nil, "4"]
    #     a[0, 3] = [ 'a', 'b', 'c' ] #=> ["a", "b", "c", rdf:nil, "4"]
    #     a[1..2] = [ 1, 2 ]          #=> ["a", 1, 2, rdf:nil, "4"]
    #     a[0, 2] = "?"               #=> ["?", 2, rdf:nil, "4"]
    #     a[0..2] = "A"               #=> ["A", "4"]
    #     a[-1]   = "Z"               #=> ["A", "Z"]
    #     a[1..-1] = nil              #=> ["A", rdf:nil]
    #     a[1..-1] = []               #=> ["A"]
    #     a[0, 0] = [ 1, 2 ]          #=> [1, 2, "A"]
    #     a[3, 0] = "B"               #=> [1, 2, "A", "B"]
    #
    # @overload []=(index, term)
    #   Replaces the element at `index` with `term`.
    #   @param [Integer] index
    #   @param [RDF::Term] term
    #     A non-RDF::Term is coerced to a Literal.
    #   @return [RDF::Term]
    #   @raise [IndexError]
    #
    # @overload []=(start, length, value)
    #   Replaces a subarray from the `start` index for `length` elements with `value`. Value is a {RDF::Term}, Array of {RDF::Term}, or {RDF::List}.
    #   @param [Integer] start
    #   @param [Integer] length
    #   @param [RDF::Term, Array<RDF::Term>, RDF::List] value
    #     A non-RDF::Term is coerced to a Literal.
    #   @return [RDF::Term, RDF::List]
    #   @raise [IndexError]
    #
    # @overload []=(range, value)
    #   Replaces a subarray from the `start` index for `length` elements with `value`. Value is a {RDF::Term}, Array of {RDF::Term}, or {RDF::List}.
    #   @param [Range] range
    #   @param [RDF::Term, Array<RDF::Term>, RDF::List] value
    #     A non-RDF::Term is coerced to a Literal.
    #   @return [RDF::Term, RDF::List]
    #   @raise [IndexError]
    # @since 1.1.15
    def []=(*args)
      start, length = 0, 0

      ary = self.to_a

      value = case args.last
      when Array then args.last
      when RDF::List then args.last.to_a
      else [args.last]
      end

      ret = case args.length
      when 3
        start, length = args[0], args[1]
        ary[start, length] = value
      when 2
        case args.first
        when Integer
          raise ArgumentError, "Index form of []= takes a single term" if args.last.is_a?(Array)
          ary[args.first] = args.last.is_a?(RDF::List) ? args.last.subject : args.last
        when Range
          ary[args.first] = value
        else
          raise ArgumentError, "Index form of must use an integer or range"
        end
      else
        raise ArgumentError, "List []= takes one or two index values"
      end

      # Clear the list and create a new list using the existing subject
      subject = @subject unless ary.empty? || @subject == RDF.nil
      self.clear
      new_list = RDF::List.new(subject: subject, graph: @graph, values: ary)
      @subject = new_list.subject
      ret # Returns inserted values
    end

    ##
    # Appends an element to the head of this list. Existing references are not updated, as the list subject changes as a side-effect.
    #
    # @example
    #   RDF::List[].unshift(1).unshift(2).unshift(3) #=> RDF::List[3, 2, 1]
    #
    # @param  [RDF::Term, Array<RDF::Term>, RDF::List] value
    #   A non-RDF::Term is coerced to a Literal
    # @return [RDF::List]
    # @see    http://ruby-doc.org/core-2.2.2/Array.html#method-i-unshift
    #
    def unshift(value)
      value = normalize_value(value)

      new_subject, old_subject = RDF::Node.new, subject

      graph.insert([new_subject, RDF.first, value.is_a?(RDF::List) ? value.subject : value])
      graph.insert([new_subject, RDF.rest, old_subject])

      @subject = new_subject

      return self
    end

    ##
    # Removes and returns the element at the head of this list.
    #
    # @example
    #   RDF::List[1,2,3].shift              #=> 1
    #
    # @return [RDF::Term]
    # @see    http://ruby-doc.org/core-2.2.2/Array.html#method-i-shift
    def shift
      return nil if empty?

      value = first
      old_subject, new_subject = subject, rest_subject
      graph.delete([old_subject, RDF.type, RDF.List])
      graph.delete([old_subject, RDF.first, value])
      graph.delete([old_subject, RDF.rest, new_subject])

      @subject = new_subject
      return value
    end

    ##
    # Empties this list
    #
    # @example
    #   RDF::List[1, 2, 2, 3].clear    #=> RDF::List[]
    #
    # @return [RDF::List]
    # @see    http://ruby-doc.org/core-2.2.2/Array.html#method-i-clear
    def clear
      until empty?
        shift
      end
      return self
    end

    ##
    # Appends an element to the tail of this list.
    #
    # @example
    #   RDF::List[] << 1 << 2 << 3              #=> RDF::List[1, 2, 3]
    #
    # @param  [RDF::Term] value
    # @return [RDF::List]
    # @see    http://ruby-doc.org/core-2.2.2/Array.html#method-i-3C-3C
    def <<(value)
      value = normalize_value(value)

      if empty?
        @subject = new_subject = RDF::Node.new
      else
        old_subject, new_subject = last_subject, RDF::Node.new
        graph.delete([old_subject, RDF.rest, RDF.nil])
        graph.insert([old_subject, RDF.rest, new_subject])
      end

      graph.insert([new_subject, RDF.first, value.is_a?(RDF::List) ? value.subject : value])
      graph.insert([new_subject, RDF.rest, RDF.nil])

      self
    end

    ##
    # Compares this list to `other` using eql? on each component.
    #
    # @example
    #   RDF::List[1, 2, 3].eql? RDF::List[1, 2, 3]  #=> true
    #   RDF::List[1, 2, 3].eql? [1, 2, 3]           #=> true
    #
    # @param  [RDF::List] other
    # @return [Integer]
    # @see    http://ruby-doc.org/core-2.2.2/Array.html#method-i-3C-3D-3E
    def eql?(other)
      to_a.eql? other.to_a # TODO: optimize this
    end

    ##
    # Compares this list to `other` for sorting purposes.
    #
    # @example
    #   RDF::List[1] <=> RDF::List[1]           #=> 0
    #   RDF::List[1] <=> RDF::List[2]           #=> -1
    #   RDF::List[2] <=> RDF::List[1]           #=> 1
    #
    # @param  [RDF::List] other
    # @return [Integer]
    # @see    http://ruby-doc.org/core-2.2.2/Array.html#method-i-3C-3D-3E
    def <=>(other)
      to_a <=> Array(other)
    end

    ##
    # Returns `true` if this list is empty.
    #
    # @example
    #   RDF::List[].empty?                      #=> true
    #   RDF::List[1, 2, 3].empty?               #=> false
    #
    # @return [Boolean]
    # @see    http://ruby-doc.org/core-2.2.2/Array.html#method-i-empty-3F
    def empty?
      graph.query({subject: subject, predicate: RDF.first}).empty?
    end

    ##
    # Returns the length of this list.
    #
    # @example
    #   RDF::List[].length                      #=> 0
    #   RDF::List[1, 2, 3].length               #=> 3
    #
    # @return [Integer]
    # @see    http://ruby-doc.org/core-2.2.2/Array.html#method-i-length
    def length
      each.count
    end

    alias_method :size, :length

    ##
    # Returns the index of the first element equal to `value`, or `nil` if
    # no match was found.
    #
    # @example
    #   RDF::List['a', 'b', 'c'].index('a')     #=> 0
    #   RDF::List['a', 'b', 'c'].index('d')     #=> nil
    #
    # @param  [RDF::Term] value
    # @return [Integer]
    # @see    http://ruby-doc.org/core-2.2.2/Array.html#method-i-index
    def index(value)
      each.with_index do |v, i|
        return i if v == value
      end
      return nil
    end

    ##
    # Returns a slice of a list.
    #
    # @example
    #     RDF::List[1, 2, 3].slice(0)    #=> RDF::Literal(1),
    #     RDF::List[1, 2, 3].slice(0, 2) #=> RDF::List[1, 2],
    #     RDF::List[1, 2, 3].slice(0..2) #=> RDF::List[1, 2, 3]
    #
    # @return [RDF::Term]
    # @see    http://ruby-doc.org/core-2.2.2/Array.html#method-i-slice
    def slice(*args)
      case argc = args.size
        when 2 then slice_with_start_and_length(*args)
        when 1 then (arg = args.first).is_a?(Range) ? slice_with_range(arg) : at(arg)
        when 0 then raise ArgumentError, "wrong number of arguments (0 for 1)"
        else raise ArgumentError, "wrong number of arguments (#{argc} for 2)"
      end
    end
    alias :[] :slice

    ##
    # @private
    def slice_with_start_and_length(start, length)
      self.class.new(values: to_a.slice(start, length))
    end

    ##
    # @private
    def slice_with_range(range)
      self.class.new(values: to_a.slice(range))
    end

    protected :slice_with_start_and_length
    protected :slice_with_range

    ##
    # Returns element at `index` with default.
    #
    # @example
    #   RDF::List[1, 2, 3].fetch(0)             #=> RDF::Literal(1)
    #   RDF::List[1, 2, 3].fetch(4)             #=> IndexError
    #   RDF::List[1, 2, 3].fetch(4, nil)        #=> nil
    #   RDF::List[1, 2, 3].fetch(4) { |n| n*n } #=> 16
    #
    # @return [RDF::Term, nil]
    # @see    http://ruby-doc.org/core-1.9/classes/Array.html#M000420
    def fetch(index, default = UNSET)
      val = at(index)
      return val unless val.nil?

      case
        when block_given?         then yield index
        when !default.eql?(UNSET) then default
        else raise IndexError, "index #{index} not in the list #{self.inspect}"
      end
    end

    ##
    # Returns the element at `index`.
    #
    # @example
    #   RDF::List[1, 2, 3].at(0)                #=> 1
    #   RDF::List[1, 2, 3].at(4)                #=> nil
    #
    # @return [RDF::Term, nil]
    # @see    http://ruby-doc.org/core-2.2.2/Array.html#method-i-at
    def at(index)
      each.with_index { |v, i| return v if i == index }
      return nil
    end

    alias_method :nth, :at

    ##
    # Returns the first element in this list.
    #
    # @example
    #   RDF::List[*(1..10)].first               #=> RDF::Literal(1)
    #
    # @return [RDF::Term]
    def first
      graph.first_object(subject: first_subject, predicate: RDF.first)
    end

    ##
    # Returns the second element in this list.
    #
    # @example
    #   RDF::List[*(1..10)].second              #=> RDF::Literal(2)
    #
    # @return [RDF::Term]
    def second
      at(1)
    end

    ##
    # Returns the third element in this list.
    #
    # @example
    #   RDF::List[*(1..10)].third               #=> RDF::Literal(4)
    #
    # @return [RDF::Term]
    def third
      at(2)
    end

    ##
    # Returns the fourth element in this list.
    #
    # @example
    #   RDF::List[*(1..10)].fourth              #=> RDF::Literal(4)
    #
    # @return [RDF::Term]
    def fourth
      at(3)
    end

    ##
    # Returns the fifth element in this list.
    #
    # @example
    #   RDF::List[*(1..10)].fifth               #=> RDF::Literal(5)
    #
    # @return [RDF::Term]
    def fifth
      at(4)
    end

    ##
    # Returns the sixth element in this list.
    #
    # @example
    #   RDF::List[*(1..10)].sixth               #=> RDF::Literal(6)
    #
    # @return [RDF::Term]
    def sixth
      at(5)
    end

    ##
    # Returns the seventh element in this list.
    #
    # @example
    #   RDF::List[*(1..10)].seventh             #=> RDF::Literal(7)
    #
    # @return [RDF::Term]
    def seventh
      at(6)
    end

    ##
    # Returns the eighth element in this list.
    #
    # @example
    #   RDF::List[*(1..10)].eighth              #=> RDF::Literal(8)
    #
    # @return [RDF::Term]
    def eighth
      at(7)
    end

    ##
    # Returns the ninth element in this list.
    #
    # @example
    #   RDF::List[*(1..10)].ninth               #=> RDF::Literal(9)
    #
    # @return [RDF::Term]
    def ninth
      at(8)
    end

    ##
    # Returns the tenth element in this list.
    #
    # @example
    #   RDF::List[*(1..10)].tenth               #=> RDF::Literal(10)
    #
    # @return [RDF::Term]
    def tenth
      at(9)
    end

    ##
    # Returns the last element in this list.
    #
    # @example
    #   RDF::List[*(1..10)].last                 #=> RDF::Literal(10)
    #
    # @return [RDF::Term]
    # @see    http://ruby-doc.org/core-2.2.2/Array.html#method-i-last
    def last
      graph.first_object(subject: last_subject, predicate: RDF.first)
    end

    ##
    # Returns a list containing all but the first element of this list.
    #
    # @example
    #   RDF::List[1, 2, 3].rest                 #=> RDF::List[2, 3]
    #
    # @return [RDF::List]
    def rest
      (subject = rest_subject).eql?(RDF.nil) ? nil : self.class.new(subject: subject, graph: graph)
    end

    ##
    # Returns a list containing the last element of this list.
    #
    # @example
    #   RDF::List[1, 2, 3].tail                 #=> RDF::List[3]
    #
    # @return [RDF::List]
    def tail
      (subject = last_subject).eql?(RDF.nil) ? nil : self.class.new(subject: subject, graph: graph)
    end

    ##
    # Returns the first subject term constituting this list.
    #
    # This is equivalent to `subject`.
    #
    # @example
    #   RDF::List[1, 2, 3].first_subject        #=> RDF::Node(...)
    #
    # @return [RDF::Resource]
    def first_subject
      subject
    end

    ##
    # @example
    #   RDF::List[1, 2, 3].rest_subject         #=> RDF::Node(...)
    #
    # @return [RDF::Resource]
    def rest_subject
      graph.first_object(subject: subject, predicate: RDF.rest)
    end

    ##
    # Returns the last subject term constituting this list.
    #
    # @example
    #   RDF::List[1, 2, 3].last_subject         #=> RDF::Node(...)
    #
    # @return [RDF::Resource]
    def last_subject
      each_subject.to_a.last # TODO: optimize this
    end

    ##
    # Yields each subject term constituting this list.
    #
    # @example
    #   RDF::List[1, 2, 3].each_subject do |subject|
    #     puts subject.inspect
    #   end
    #
    # @return [Enumerator]
    # @see    RDF::Enumerable#each
    def each_subject
      return enum_subject unless block_given?

      subject = self.subject
      yield subject

      loop do
        rest = graph.first_object(subject: subject, predicate: RDF.rest)
        break if rest.nil? || rest.eql?(RDF.nil)
        yield subject = rest
      end
    end

    ##
    # Yields each element in this list.
    #
    # @example
    #   RDF::List[1, 2, 3].each do |value|
    #     puts value.inspect
    #   end
    #
    # @return [Enumerator]
    # @see    http://ruby-doc.org/core-1.9/classes/Enumerable.html
    def each
      return to_enum unless block_given?

      each_subject do |subject|
        if value = graph.first_object(subject: subject, predicate: RDF.first)
          yield value # FIXME
        end
      end
    end

    ##
    # Yields each statement constituting this list.
    #
    # @example
    #   RDF::List[1, 2, 3].each_statement do |statement|
    #     puts statement.inspect
    #   end
    #
    # @return [Enumerator]
    # @see    RDF::Enumerable#each_statement
    def each_statement(&block)
      return enum_statement unless block_given?

      each_subject do |subject|
        graph.query({subject: subject}, &block)
      end
    end
    alias_method :to_rdf, :each_statement

    ##
    # Returns a string created by converting each element of this list into
    # a string, separated by `sep`.
    #
    # @example
    #   RDF::List[1, 2, 3].join                 #=> "123"
    #   RDF::List[1, 2, 3].join(", ")           #=> "1, 2, 3"
    #
    # @param  [String] sep
    # @return [String]
    # @see    http://ruby-doc.org/core-2.2.2/Array.html#method-i-join
    def join(sep = $,)
      map(&:to_s).join(sep)
    end

    ##
    # Returns the elements in this list in reversed order.
    #
    # @example
    #   RDF::List[1, 2, 3].reverse              #=> RDF::List[3, 2, 1]
    #
    # @return [RDF::List]
    # @see    http://ruby-doc.org/core-2.2.2/Array.html#method-i-reverse
    def reverse
      self.class.new(values: to_a.reverse)
    end

    ##
    # Returns the elements in this list in sorted order.
    #
    # @example
    #   RDF::List[2, 3, 1].sort                 #=> RDF::List[1, 2, 3]
    #
    # @return [RDF::List]
    # @see    http://ruby-doc.org/core-2.2.2/Array.html#method-i-sort
    def sort(&block)
      self.class.new(values: super)
    end

    ##
    # Returns the elements in this list in sorted order.
    #
    # @example
    #   RDF::List[2, 3, 1].sort_by(&:to_i)      #=> RDF::List[1, 2, 3]
    #
    # @return [RDF::List]
    # @see    http://ruby-doc.org/core-2.2.2/Array.html#method-i-sort_by
    def sort_by(&block)
      self.class.new(values: super)
    end

    ##
    # Returns a new list with the duplicates in this list removed.
    #
    # @example
    #   RDF::List[1, 2, 2, 3].uniq              #=> RDF::List[1, 2, 3]
    #
    # @return [RDF::List]
    # @see    http://ruby-doc.org/core-2.2.2/Array.html#method-i-uniq
    def uniq
      self.class.new(values: to_a.uniq)
    end

    ##
    # Returns the elements in this list as an array.
    #
    # @example
    #   RDF::List[].to_a                        #=> []
    #   RDF::List[1, 2, 3].to_a                 #=> [RDF::Literal(1), RDF::Literal(2), RDF::Literal(3)]
    #
    # @return [Array]
    def to_a
      each.to_a
    end

    ##
    # Returns the elements in this list as a set.
    #
    # @example
    #   RDF::List[1, 2, 3].to_set               #=> Set[RDF::Literal(1), RDF::Literal(2), RDF::Literal(3)]
    #
    # @return [Set]
    def to_set
      require 'set' unless defined?(::Set)
      each.to_set
    end

    ##
    # Returns the subject of the list.
    #
    # @example
    #   RDF::List[].to_term                     #=> "RDF[:nil]"
    #   RDF::List[1, 2, 3].to_term              #=> "RDF::Node"
    #
    # @return [RDF::Resource]
    def to_term
      subject
    end

    ##
    # Returns a string representation of this list.
    #
    # @example
    #   RDF::List[].to_s                        #=> "RDF::List[]"
    #   RDF::List[1, 2, 3].to_s                 #=> "RDF::List[1, 2, 3]"
    #
    # @return [String]
    def to_s
      'RDF::List[' + join(', ') + ']'
    end

    ##
    # Returns a developer-friendly representation of this list.
    #
    # @example
    #   RDF::List[].inspect                     #=> "#<RDF::List(_:g2163790380)>"
    #
    # @return [String]
    def inspect
      if self.equal?(NIL)
        'RDF::List::NIL'
      else
        sprintf("#<%s:%#0x(%s)>", self.class.name, __id__, join(', '))
      end
    end

    private

    ##
    # Normalizes `Array` to `RDF::List` and `nil` to `RDF.nil`.
    #
    # @param value [Object]
    # @return [RDF::Value, Object] normalized value
    def normalize_value(value)
      case value
        when nil         then RDF.nil
        when RDF::Value  then value
        when Array       then self.class.new(subject: nil, graph: graph, values: value)
        else value
      end
    end
  end
end
