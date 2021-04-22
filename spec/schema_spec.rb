require "spec_helper"

RSpec.describe GraphitiGraphQL::Schema do
  # Todo and one in the other spec vlaidating it works w/merge
  describe ".generate" do
    context "when an existing graphql-ruby schema class" do
      let(:custom_type) do
        Class.new(GraphQL::Schema::Object) do
          graphql_name "GQLCustomType"
          field :gql_specific, String, null: false

          def gql_specific
            if context[:user] || context[:object]
              context[:user] || context[:object].thing
            else
              "works!"
            end
          end
        end
      end

      let(:orphan_type) do
        Class.new(GraphQL::Schema::Object) do
          graphql_name "GQLOrphan"
        end
      end

      let(:query_type) do
        klass = Class.new(GraphQL::Schema::Object) {
          graphql_name "MyQueryType"
          def things
            [OpenStruct.new(gql_specific: "works!")]
          end
        }
        klass.field :things, [custom_type], null: false
        klass
      end

      let(:gql_schema) do
        klass = Class.new(GraphQL::Schema)
        klass.query(query_type)
        klass.orphan_types([orphan_type])
        klass.max_depth(3)
        klass
      end

      before do
        GraphitiGraphQL.schema_class = gql_schema
        schema!
      end

      it "does not modify the existing class" do
        expect(gql_schema.types.keys.length)
          .to be < GraphitiGraphQL.schemas.graphql.types.length
        expect(gql_schema.types).to include("GQLCustomType")
        expect(gql_schema.types).to_not include("POROEmployee")
      end

      it "does not modify the existing query" do
        expect(query_type.fields.keys).to eq(["things"])
      end

      it "is merged with graphiti-generated schema" do
        types = GraphitiGraphQL.schemas.graphql.types
        expect(types).to include("GQLCustomType")
        expect(types).to include("POROEmployee")
        query = GraphitiGraphQL.schemas.graphql.query
        expect(query.fields).to have_key("employees")
        expect(query.fields).to have_key("things")
      end

      it "appends rather than overwrites orphan types" do
        expect(gql_schema.orphan_types).to eq([orphan_type])
        orphans = GraphitiGraphQL.schemas.graphql.orphan_types
        expect(orphans.length).to be > 1
        expect(orphans).to include(orphan_type)
      end

      it "can execute raw GQL queries" do
        json = run(%(
          query {
            things {
              gqlSpecific
            }
          }
        ))
        expect(json).to eq({
          things: [{gqlSpecific: "works!"}]
        })
      end

      it "can execute Graphiti GQL queries" do
        PORO::Employee.create(first_name: "Jenny")
        json = run(%(
          query {
            employees {
              nodes {
                firstName
              }
            }
          }
        ))
        expect(json).to eq({
          employees: {nodes: [{firstName: "Jenny"}]}
        })
      end

      it "respects max_depth when Graphiti GQL query" do
        json = run(%(
          query {
            employees {
              nodes {
                positions {
                  nodes {
                    department {
                      name
                    }
                  }
                }
              }
            }
          }
        ))
        expect(json).to eq({
          errors: [{
            message: "Query has depth of 6, which exceeds max depth of 3"
          }]
        })
      end

      context "when there are no sorts" do
        let(:resource) do
          Class.new(PORO::ApplicationResource) do
            def self.name
              "PORO::EmployeeResource"
            end
            self.type = :employees
            self.graphql_entrypoint = :employees
            attribute :id, :string, only: [:readable]
            attribute :name, :string, only: [:readable]
          end
        end

        before do
          schema!([resource])
        end

        it "does not generate sort classes" do
          schema = GraphitiGraphQL.schemas.graphql
          expect(schema.types.keys.grep(/sort/i)).to be_empty
        end

        it "does not accept the sort argument" do
          schema = GraphitiGraphQL.schemas.graphql
          expect(schema.query.fields["employees"].arguments.keys)
            .to_not include("sort")
        end
      end

      context "when there are no filters" do
        let(:resource) do
          Class.new(PORO::ApplicationResource) do
            def self.name
              "PORO::EmployeeResource"
            end
            self.type = :employees
            self.graphql_entrypoint = :employees
            attribute :id, :string, only: [:readable]
            attribute :name, :string, only: [:readable]
          end
        end

        before do
          schema!([resource])
        end

        it "does not generate filter classes" do
          schema = GraphitiGraphQL.schemas.graphql
          expect(schema.types.keys.grep(/filter/i)).to be_empty
        end

        it "does not accept the filter argument" do
          schema = GraphitiGraphQL.schemas.graphql
          expect(schema.query.fields["employees"].arguments.keys)
            .to_not include("filter")
        end
      end

      context "when .define_context set" do
        before do
          GraphitiGraphQL.config.define_context do |ctx|
            {user: ctx.current_user}
          end
        end

        it "can set the GQL context via the Graphiti context" do
          ctx = double(current_user: "user!")
          Graphiti.with_context ctx do
            json = run(%(
              query {
                things {
                  gqlSpecific
                }
              }
            ))
            expect(json).to eq({
              things: [{gqlSpecific: "user!"}]
            })
          end
        end
      end

      context "when .define_context not set" do
        it "defaults key to :object" do
          ctx = double(thing: "gotme!")
          Graphiti.with_context ctx do
            json = run(%(
              query {
                things {
                  gqlSpecific
                }
              }
            ))
            expect(json).to eq({
              things: [{gqlSpecific: "gotme!"}]
            })
          end
        end
      end
    end

    context "when there are remote resources" do
      let!(:resource) do
        Class.new(PORO::EmployeeResource) do
          def self.name
            "PORO::EmployeeResource"
          end
          has_many :remote_positions, remote: "http://test.com"
        end
      end

      it "skips them" do
        expect {
          schema!([resource])
        }.to_not raise_error
        employee_type = GraphitiGraphQL.schemas.graphql.types["POROEmployee"]
        fields = employee_type.fields
        expect(fields).to_not have_key("remotePositions")
      end
    end

    # TODO on attribute, on filter, on sort, etc
    context "when there is a graphiti description" do
      let!(:resource) do
        Class.new(PORO::EmployeeResource) do
          def self.name
            "PORO::EmployeeResource"
          end
        end
      end

      def self.yml_setup
        before do
          @original = I18n.load_path
          yml = "./support/locale/documentation_i18n.yml"
          I18n.load_path = [File.expand_path(yml, __dir__)]
          resource.attribute :foo, :string
          resource.extra_attribute :extra_foo, :string
          schema!([resource])
        end

        after do
          I18n.load_path = @original
        end
      end

      describe "on a resource" do
        context "in-line" do
          before do
            resource.description = "my d3scription"
            schema!([resource])
          end

          it "is present in the GQL schema" do
            employee_type = GraphitiGraphQL.schemas.graphql.types["POROEmployee"]
            expect(employee_type.description).to eq("my d3scription")
          end
        end

        context "via yml file" do
          yml_setup

          it "is present in the GQL schema" do
            employee_type = GraphitiGraphQL.schemas.graphql.types["POROEmployee"]
            expect(employee_type.description).to eq("my YML d3scription")
          end
        end
      end

      describe "on a relationship" do
        context "in-line" do
          before do
            resource.has_many :positions, description: "position inline desc"
            schema!([resource])
          end

          it "is present in the GQL schema" do
            employee_type = GraphitiGraphQL.schemas.graphql
              .types["POROEmployee"]
            field = employee_type.fields["positions"]
            expect(field.description).to eq("position inline desc")
          end
        end

        context "via yml file" do
          yml_setup

          it "is present in the GQL schema" do
            employee_type = GraphitiGraphQL.schemas.graphql
              .types["POROEmployee"]
            field = employee_type.fields["positions"]
            expect(field.description).to eq("position yml desc")
          end
        end
      end

      # describe "on a filter" do
      #   context "in-line via resource" do
      #   end
      # end

      # describe "on a sort" do
      #   context "in-line via resource" do
      #   end
      # end

      describe "on an attribute" do
        context "in-line" do
          before do
            resource.attribute :foo, :string, description: "my description"
            schema!([resource])
          end

          it "is present in the GQL schema" do
            employee_type = GraphitiGraphQL.schemas.graphql.types["POROEmployee"]
            expect(employee_type.fields["foo"].description)
              .to eq("my description")
          end
        end

        context "via yml" do
          yml_setup

          it "is present in the GQL schema" do
            employee_type = GraphitiGraphQL.schemas.graphql.types["POROEmployee"]
            expect(employee_type.fields["foo"].description)
              .to eq("Description from yml")
          end
        end
      end

      describe "on an extra_attribute" do
        context "in-line" do
          before do
            resource.extra_attribute \
              :extra_foo,
              :string,
              description: "my extra description"
            schema!([resource])
          end

          it "is present in the GQL schema" do
            employee_type = GraphitiGraphQL.schemas.graphql
              .types["POROEmployee"]
            expect(employee_type.fields["extraFoo"].description)
              .to eq("my extra description")
          end
        end

        context "via yml" do
          yml_setup

          it "is present in the GQL schema" do
            employee_type = GraphitiGraphQL.schemas.graphql
              .types["POROEmployee"]
            expect(employee_type.fields["extraFoo"].description)
              .to eq("Extra description from yml")
          end
        end
      end
    end
  end
end