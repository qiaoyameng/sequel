# frozen-string-literal: true
#
# The heterogeneous_insert extension provides streaming import of hashes
# whose keys differ from row to row, preserving the distinction between a
# missing key and an explicit +nil+ value:
#
# * Columns omitted from a hash are not present in the INSERT statement,
#   so the database fills them with their column defaults.
# * Columns present with a +nil+ value are inserted as NULL.
# * An empty hash inserts a row using DEFAULT VALUES, so all columns
#   receive their defaults.
#
# Unlike Dataset#multi_insert, rows are not padded to a shared set of
# columns. The argument only needs to be an enumerable of hashes (such as
# an Enumerator), and rows are consumed and inserted with bounded memory
# use: rows are buffered only up to the current batch and flushed while
# enumeration continues, so a large or lazy source does not need to be
# loaded into memory first.
#
# Rows are combined into a single multi-row INSERT statement only with
# adjacent rows that use the same set of columns. Rows are never reordered
# into global groups, so database triggers observe the rows in their
# original order:
#
#   DB.extension :heterogeneous_insert
#   DB[:items].heterogeneous_insert(
#     [{a: 1}, {a: 2, b: 3}, {b: 4}, {a: 5}]
#   )
#   # INSERT INTO items (a) VALUES (1), (2)
#   # INSERT INTO items (a, b) VALUES (2, 3)
#   # INSERT INTO items (b) VALUES (4)
#   # INSERT INTO items (a) VALUES (5)
#
# Key order within the hashes does not matter; only the set of keys.
#
# By default, the entire enumeration is inserted inside a single
# transaction. If the enumerator raises while being consumed, or a later
# batch fails (for example due to a constraint violation), all inserts are
# rolled back. The return value is always nil; generated primary keys are
# not returned.
#
# Loading this extension is optional: Dataset#heterogeneous_insert and its
# alias Dataset#heterogeneous_import are available on every dataset. The
# extension exists so it can be enabled explicitly (globally, per
# database, or per dataset) in the usual way:
#
#   Sequel.extension :heterogeneous_insert
#   DB.extension :heterogeneous_insert
#   DB[:items].extension(:heterogeneous_insert)
#
# Options:
# :commit_every :: Maximum number of rows to insert with a single INSERT
#                  statement. Defaults to the dataset's
#                  #default_import_slice, or to
#                  #heterogeneous_insert_default_slice when the adapter
#                  does not impose a limit, so memory use stays bounded.
#                  This controls batch size only; it never opens separate
#                  transactions, the whole import still runs in one
#                  transaction by default.
# :slice :: Alias for :commit_every.
# :max_parameters :: Maximum number of bound parameters a single INSERT
#                     statement may use (rows times columns). Rows are
#                     sliced so that statements stay within the limit.
#                     A single row with more columns than the limit raises
#                     Sequel::InvalidValue before the row itself is
#                     executed, identifying its zero-based position.
# :server :: Set the server/shard to use for the transaction and insert
#            queries.
# :skip_transaction :: Do not wrap the import in a transaction.
module Sequel
  # Marker module for the heterogeneous_insert extension. The actual
  # Dataset#heterogeneous_insert and Dataset#heterogeneous_import methods
  # are part of Dataset's core API; registering the module lets the
  # extension be enabled explicitly per database or per dataset.
  module HeterogeneousInsert
  end

  Dataset.register_extension(:heterogeneous_insert, HeterogeneousInsert)
end
