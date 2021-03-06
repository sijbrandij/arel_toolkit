describe 'Arel.enhance' do
  it 'uses brackets to access children' do
    result = Arel.sql_to_arel('SELECT 1, 2 FROM posts WHERE id = 1')
    tree = Arel.enhance(result.first)

    expect(tree['ast']['cores'][0]['source']['left'].object).to eq Arel::Table.new('posts')
  end

  it 'fails when a child does not exist using brackets' do
    result = Arel.sql_to_arel('SELECT 1, 2 FROM posts WHERE id = 1')
    tree = Arel.enhance(result.first)

    expect do
      tree['unknown']
    end.to raise_error(/key not found/)
  end

  it 'uses regular method accessors to access children' do
    result = Arel.sql_to_arel('SELECT 1, 2 FROM posts WHERE id = 1')
    tree = Arel.enhance(result.first)

    expect(tree.ast.cores[0].source.left.object).to eq Arel::Table.new('posts')
  end

  it 'fails when a child does not exist using accessors' do
    result = Arel.sql_to_arel('SELECT 1, 2 FROM posts WHERE id = 1')
    tree = Arel.enhance(result.first)

    expect do
      tree.unknown
    end.to raise_error(/undefined method `unknown'/)
  end

  it 'correctly handles respond_to and method for method missing' do
    result = Arel.sql_to_arel('SELECT 1, 2 FROM posts WHERE id = 1')
    tree = Arel.enhance(result.first)

    expect(tree).to respond_to(:ast)
    expect(tree.method(:ast)).to_not be_nil
  end

  it 'returns the same enhanced AST when the AST is already enhanced' do
    result = Arel.sql_to_arel('SELECT 1, 2 FROM posts WHERE id = 1')
    tree = Arel.enhance(result.first)

    expect(Arel.enhance(tree)).to eql(tree)
  end

  it 'prints a pretty ast' do
    result = Arel.sql_to_arel('SELECT 1, 2 FROM posts WHERE id = 1')
    tree = Arel.enhance(result)

    verify { tree.inspect }
  end

  it 'prints the same SQL' do
    result = Arel.sql_to_arel('SELECT 1, 2 FROM posts WHERE id = 1')
    tree = Arel.enhance(result)

    expect(tree.to_sql).to eq result.to_sql
  end

  it 'returns sql and binds for multiple queries' do
    bind1 = Post.predicate_builder.build_bind_attribute(:id, 1)
    sql1 = 'SELECT 1 FROM posts WHERE id = $1'
    bind2 = Post.predicate_builder.build_bind_attribute(:id, 2)
    sql2 = 'SELECT 1 FROM posts WHERE id = $2'

    binds = [bind1, bind2]
    sql = "#{sql1}; #{sql2}"

    result = Arel.sql_to_arel(sql, binds: binds)
    tree = Arel.enhance(result)
    parsed_sql, binds = tree.to_sql_and_binds

    expect(parsed_sql).to_not eq(sql)

    expect do
      ActiveRecord::Base.connection.exec_cache(parsed_sql, 'TEST', binds)
    end.to raise_error(/cannot insert multiple commands into a prepared statement/)
  end

  it 'replaces a node using a setter' do
    result = Arel.sql_to_arel('SELECT 1, 2 FROM posts WHERE id = 1')
    tree = Arel.enhance(result)
    old_projections = tree[0]['ast']['cores'][0]['projections']
    new_projections = [3, 4]

    expect do
      old_projections.replace(new_projections)
    end
      .to change { tree.to_sql }
      .from('SELECT 1, 2 FROM "posts" WHERE "id" = 1')
      .to('SELECT 3, 4 FROM "posts" WHERE "id" = 1')
  end

  it 'replaces a node using an instance variable' do
    result = Arel.sql_to_arel('SELECT 1::integer')
    tree = Arel.enhance(result)
    old_type_name = tree[0]['ast']['cores'][0]['projections'][0]['type_name']
    new_type_name = 'real'

    expect do
      old_type_name.replace(new_type_name)
    end
      .to change { tree.to_sql }
      .from('SELECT 1::integer')
      .to('SELECT 1::real')
  end

  it 'replaces a node using an array modification' do
    result = Arel.sql_to_arel('SELECT "a", "b"')
    tree = Arel.enhance(result)
    old_projection = tree[0]['ast']['cores'][0]['projections'][0]
    new_projection = Arel::Nodes::UnqualifiedColumn.new Arel::Attribute.new(nil, 'c')

    expect do
      old_projection.replace(new_projection)
    end
      .to change { tree.to_sql }
      .from('SELECT "a", "b"')
      .to('SELECT "c", "b"')
  end

  it 'removes a node using an array modification' do
    result = Arel.sql_to_arel('SELECT 1, 2 FROM posts WHERE id = 1')
    tree = Arel.enhance(result)

    expect do
      tree[0]['ast']['cores'][0]['wheres'].remove
      tree[0]['ast']['cores'][0]['projections'][1].remove
    end
      .to change { tree.to_sql }
      .from('SELECT 1, 2 FROM "posts" WHERE "id" = 1')
      .to('SELECT 1 FROM "posts"')
  end

  it 'can enhance a Hash like object' do
    sql = nil
    binds = nil

    middleware = lambda do |next_arel, next_middleware, _context|
      next_arel.query(class: Arel::InsertManager).each do
        sql, binds = next_arel.to_sql_and_binds
      end

      next_middleware.call(next_arel)
    end

    Arel.middleware.append(middleware) do
      Post.create additional_data: { foo: :bar }
    end

    expect(sql).to eq 'INSERT INTO "posts" ("additional_data", "created_at", "updated_at") ' \
                      'VALUES ($1, $2, $3) RETURNING "id"'
  end

  it 'marks a tree as dirty when modified', focus: true do
    result = Arel.sql_to_arel('SELECT 1, 2 FROM posts WHERE id = 1')
    tree = Arel.enhance(result)

    expect do
      tree[0]['ast']['cores'][0]['wheres'].remove
    end.to change { tree.dirty? }.from(false).to(true)
  end

  it 'updates the enhanced tree when mutating' do
    result = Arel.sql_to_arel('SELECT 1, 2 FROM posts WHERE id = 1')
    tree = Arel.enhance(result)
    enhanced_nodes = tree.each.to_a
    where_nodes = tree[0]['ast']['cores'][0]['wheres'].remove.each.to_a
    projections_nodes = tree[0]['ast']['cores'][0]['projections'][0].remove.each.to_a

    expect(enhanced_nodes).to all(satisfy { |n| n.root_node == tree.root_node })
    expect(where_nodes).to all(satisfy { |n| n.root_node == tree.root_node })
    expect(projections_nodes).to all(satisfy { |n| n.root_node == tree.root_node })

    expect(where_nodes).to all(satisfy { |n| n.full_path.map(&:value).include?('cores') })
    expect(projections_nodes).to all(satisfy { |n| n.full_path.map(&:value).include?('cores') })
  end

  it 'returns the partial enhanced tree after mutating' do
    result = Arel.sql_to_arel('SELECT 1, 2 FROM posts WHERE id = 1')
    tree = Arel.enhance(result)
    where_tree = tree[0]['ast']['cores'][0]['wheres'].remove

    expect(where_tree.full_path.map(&:value)).to eq [0, 'ast', 'cores', 0, 'wheres']
    expect(where_tree.parent.object).to be_a(Arel::Nodes::SelectCore)
  end

  it 'can update the ast with an existing enhanced ast' do
    result = Arel.sql_to_arel("SELECT id FROM users WHERE username ILIKE '%friend%'")
    tree = Arel.enhance(result)

    new_table = User.arel_table.dup
    new_table.name = 'active_users'
    new_enhanced_table = Arel.enhance(new_table)

    old_table = tree.child_at_path([0, 'ast', 'cores', 0, 'source', 'left'])
    new_node_from_replace = nil

    expect do
      new_node_from_replace = old_table.replace(new_enhanced_table)
    end
      .to change { new_enhanced_table.full_path.map(&:value) }
      .from([])
      .to([0, 'ast', 'cores', 0, 'source', 'left'])

    new_table_from_tree = tree.child_at_path([0, 'ast', 'cores', 0, 'source', 'left'])
    expect(new_table_from_tree).is_a?(Arel::Table)

    expect(new_node_from_replace).to eq new_enhanced_table
    expect(new_node_from_replace.root_node).to eq tree.root_node

    expect(result.to_sql)
      .to eq "SELECT \"id\" FROM \"users\" WHERE \"username\" ILIKE '%friend%'"
  end

  it 'does not change the original arel when replacing' do
    result = Arel.sql_to_arel('SELECT 1, 2 FROM posts WHERE id = 1')
    tree = Arel.enhance(result)
    old_projections = tree[0]['ast']['cores'][0]['projections']
    new_projections = [3, 4]

    expect do
      old_projections.replace(new_projections)
    end.to_not(change { result.to_sql })
  end

  it 'makes a deep copy of the arel when modified' do
    result = Arel.sql_to_arel('SELECT 1, 2 FROM posts WHERE id = 1')
    original_arel = result

    tree = Arel.enhance(original_arel)
    tree[0]['ast']['cores'][0]['source']['left']['name'].replace('comments')
    new_arel = tree.object

    expect(original_arel).to be_not_identical_arel(new_arel)
  end

  it 'does not make a deep copy of the arel if not modified' do
    result = Arel.sql_to_arel('SELECT 1, 2 FROM posts WHERE id = 1')
    original_arel = result

    tree = Arel.enhance(original_arel)
    new_arel = tree.object

    expect(original_arel).to be_identical_arel(new_arel)
  end
end
