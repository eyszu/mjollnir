-- Seed data for the Mjollnir vs crystal-pg benchmark. Not timed.
drop table if exists bench_nums, bench_text, bench_mixed, bench_items, bench_json, bench_arr, bench_ins;

create table bench_nums as
  select g::int4 as id, (g * 7)::int8 as a, (g % 1000)::int4 as b from generate_series(1, 1000000) g;

create table bench_text as
  select g::int4 as id, md5(g::text) as name, md5(g::text) || '@example.com' as email,
         repeat(md5(g::text), 2) as bio
  from generate_series(1, 300000) g;

create table bench_mixed as
  select g::int4 as id, (g / 3.0)::float8 as score, ('user' || g)::text as name,
         (g % 2 = 0) as active,
         ('2020-01-01 00:00:00+00'::timestamptz + (g || ' seconds')::interval) as ts,
         md5(g::text)::uuid as uid
  from generate_series(1, 200000) g;

create table bench_items (id int primary key, name text, score float8);
insert into bench_items
  select g, 'item-' || g, g * 0.5 from generate_series(1, 100000) g;

create table bench_json (id int primary key, doc jsonb);
insert into bench_json
  select g, jsonb_build_object('id', g, 'name', 'item ' || g,
                               'tags', jsonb_build_array('a', 'b', 'c'),
                               'nested', jsonb_build_object('flag', g % 2 = 0))
  from generate_series(1, 20000) g;

create table bench_arr (id int, xs int4[]);
insert into bench_arr
  select g, array(select (g + i)::int4 from generate_series(1, 20) i) from generate_series(1, 50000) g;

create table bench_ins (id int, name text, score float8);

analyze;
