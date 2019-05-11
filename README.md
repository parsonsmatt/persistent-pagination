# persistent-pagination

[![Build Status](https://travis-ci.org/parsonsmatt/persistent-pagination.svg?branch=master)](https://travis-ci.org/parsonsmatt/persistent-pagination) ![Hackage-Deps](https://img.shields.io/hackage-deps/v/persistent-pagination.svg)

A library that provides Correct pagination behavior.

# Why not use `LIMIT/OFFSET`?

Ok so here's the thing.

`LIMIT/OFFSET` is bad.
When you do a query that has a limit and an offset, the database server must process *the entire query* up to the `LIMIT + OFFSET`.
If you have `LIMIT 50 OFFSET 150`, then the database has to load all 200 rows, then drop the first 150.
So as you page through your database, you're loading more and more data.
Eventually, to reach the last page of data, the database is forced to load the entire result set before it can start pruning it down to the last bit.

As far as the database is concerned, it's exactly the same amount of work to deliver the entire dang dataset as it is to deliver the last page of the dataset!

[Here's a good article explaining more](https://use-the-index-luke.com/sql/partial-results/fetch-next-page).

# But I don't care about performance

Well, correctness is a problem with `LIMIT/OFFSET` too.
You might receive rows multiple times, and you might receive some rows not-at-all.
It comes down to how your data is ordered.

How is your data ordered?
If you don't specify a sort order, it's probably taking the primary key.
However, if you don't specify a sort order, then the order is totally non-deterministic!
There's nothing stopping your database server from returning a different ordering on two different "pages" of a query.
If you expect that you'll be processing each row in your database exactly once, then this can throw a wrench into things.

We need to provide an `ORDER BY` clause when we're paginating, or we'll get these problems.

If someone inserts into or deletes data from your database while you're paging through the data, then you may skip rows or get duplicate rows again.

# The Ideal Pagination

- `ORDER BY` an column
- That column should be immutable and monotonic - the ideal column for this is a `created` timestamp.
- That column should have an index
- Instead of talking about "pages", we talk about "ranges"

This requires a slightly different way of thinking about pagination.
Instead of saying "Give me page 6 of this query," we're going to say:

> I want all the rows with a `$COLUMN` value at least `X` and at most `Y` in chunks of 50.

The server is going to respond with:

> Here's 50 rows starting at `X` and ending at `Z`.

The next request we make will say:

> I want all the rows with a `$COLUMN` value at least `Z` and at most `Y` in chunks of 50.

And the server will continue giving results, until there are less than `50` rows in the response, at which point we've "run out" of rows satisfying the range.
