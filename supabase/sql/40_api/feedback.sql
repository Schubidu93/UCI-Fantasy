-- p_images: [{"mime": "image/jpeg", "data": "<base64>"}, …] (höchstens 5, je höchstens 2 MB)
drop function if exists submit_feedback(text, uuid, text, text, jsonb);
create or replace function submit_feedback(p_message text, p_league uuid, p_page text, p_device text, p_images jsonb default '[]')
returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare v_id bigint; v_img jsonb; v_data bytea;
begin
  if auth.uid() is null then raise exception 'Bitte zuerst anmelden.'; end if;
  if coalesce(btrim(p_message), '') = '' and jsonb_array_length(coalesce(p_images, '[]')) = 0 then
    raise exception 'Bitte schreib etwas oder hänge ein Bild an.';
  end if;
  if length(p_message) > 5000 then raise exception 'Der Text ist zu lang (max. 5000 Zeichen).'; end if;
  if jsonb_array_length(coalesce(p_images, '[]')) > 5 then raise exception 'Höchstens 5 Bilder.'; end if;
  if (select count(*) from feedback where user_id = auth.uid() and created_at > now() - interval '1 day') >= 20 then
    raise exception 'Heute wurde schon sehr viel Feedback geschickt – bitte morgen wieder.';
  end if;
  insert into feedback (user_id, user_email, league_id, league_name, team_name, page, device, message)
  values (auth.uid(), (select email from auth.users where id = auth.uid()), p_league,
          (select name from leagues where id = p_league and is_member(id)),
          (select team_name from managers where league_id = p_league and user_id = auth.uid()),
          left(p_page, 200), left(p_device, 300), coalesce(btrim(p_message), ''))
  returning id into v_id;
  for v_img in select * from jsonb_array_elements(coalesce(p_images, '[]')) loop
    if coalesce(v_img->>'mime', '') not in ('image/jpeg', 'image/png', 'image/webp') then raise exception 'Nur Bilder (JPG, PNG).'; end if;
    v_data := decode(v_img->>'data', 'base64');
    if length(v_data) > 2 * 1024 * 1024 then raise exception 'Ein Bild ist zu groß (max. 2 MB).'; end if;
    insert into feedback_images (feedback_id, mime, data) values (v_id, v_img->>'mime', v_data);
  end loop;
  begin
    perform dispatch_workflow('feedback.yml');
  exception when others then null;    -- ohne Token: Versand beim nächsten Zeitplaner-Lauf
  end;
  return v_id;
end $$;

