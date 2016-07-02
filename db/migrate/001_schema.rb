class Schema < ActiveRecord::Migration[5.0]
  def change
    create_table :submitters, force: true do |t|
      t.string :name
    end

    create_table :projects, force: true do |t|
      t.string :name
    end

    create_table :delegates, force: true do |t|
      t.string :name
    end

    create_table :states, force: true do |t|
      t.string :name
    end

    create_table :patches, force: true do |t|
      t.string :commit_ref
      t.datetime :date
      t.references :delegate
      t.text :filename
      t.string :msgid
      t.string :name
      t.references :project
      t.references :submitter
      t.references :state
    end

    add_index :patches, :msgid
  end
end
