-- Namen vergleichbar machen: 'POGAČAR Tadej' = 'Tadej Pogacar' (Akzente weg, Wörter sortiert)
create extension if not exists unaccent with schema extensions;
create or replace function norm_name(p text) returns text
language sql immutable parallel safe set search_path = public, extensions as $$
  select array_to_string(array(select w from unnest(regexp_split_to_array(
           lower(extensions.unaccent('extensions.unaccent'::regdictionary, coalesce(p, ''))), '[^a-z0-9]+')) w
         where w <> '' order by w), ' ');
$$;
create index if not exists riders_norm_name on riders (gender, norm_name(name));

