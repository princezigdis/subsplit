-- =====================================================================
--  SUBSPLIT · 003_seed_services.sql  (run once, after 001 and 002)
--  Starting list of services and plans. Everything here is editable in
--  Admin -> Services. Nothing is hard-coded in the website.
--
--  PRICES ARE STARTING VALUES. Check each service's current Nigerian
--  price before going live and update it in Admin -> Services.
--
--  Seat limits follow each service's own family/sharing rules:
--   * "max seats" = people who can join, NOT counting the host.
--   * Services whose terms do not allow sharing are added switched OFF
--     (active = false) so they never appear until you decide otherwise.
-- =====================================================================

insert into public.services (name, category, logo_color, description, sharing_rules, notes, active, sort) values
 ('Netflix', 'Entertainment', '#E50914', 'Movies and series.',
  'Netflix is meant for one household. The Premium plan has 5 profiles and plays on 4 screens at the same time. Netflix may block accounts shared outside a household.',
  'Seat limit 4: Premium plays on 4 screens at once and the host keeps one profile. Check the current price on netflix.com/ng.', true, 1),
 ('YouTube Premium', 'Entertainment', '#FF0033', 'Ad-free YouTube and YouTube Music.',
  'Family plan: the family manager can invite up to 5 people aged 13+ who live in the same household. Google checks members'' location.',
  'Check the current family price in the YouTube app.', true, 2),
 ('Prime Video', 'Entertainment', '#1A98FF', 'Amazon Originals, movies and series.',
  'One account can have up to 6 profiles and stream on 3 devices at the same time.',
  'Seat limit 3 because only 3 streams can play at once. Check the current price on primevideo.com.', true, 3),
 ('Disney+', 'Entertainment', '#113CCF', 'Disney, Pixar, Marvel and Star Wars.',
  'Disney+ is not officially sold in Nigeria.', 'Kept OFF: not officially available in Nigeria.', false, 4),
 ('Spotify', 'Music', '#1DB954', 'Music and podcasts.',
  'Premium Family: the plan manager plus up to 5 members (6 accounts) who live at the same address. Each member uses their own Spotify account.',
  'Check the current Premium Family price on spotify.com/ng.', true, 5),
 ('Apple Music', 'Music', '#FA2D48', 'Music on iPhone, Android and the web.',
  'Family plan through Apple Family Sharing: the organiser plus up to 5 people. Each member uses their own Apple ID.',
  'Check the current family price in the Apple Music app.', true, 6),
 ('Microsoft 365', 'Software', '#D83B01', 'Word, Excel, PowerPoint and 1 TB OneDrive each.',
  'Microsoft 365 Family: share with up to 5 other people. Each person signs in with their own Microsoft account.',
  'Check the current Family price on microsoft.com.', true, 7),
 ('Canva', 'Software', '#7D2AE8', 'Design tool.',
  'Canva Pro is for one person. Canva Teams is billed per member, so adding people raises the owner''s bill.',
  'Kept OFF: check Canva''s team billing before allowing listings.', false, 8),
 ('CapCut', 'Software', '#1F1F1F', 'Video editing.',
  'CapCut Pro is for one person. Sharing a login breaks CapCut''s terms.', 'Kept OFF: personal subscription.', false, 9),
 ('Google One', 'Cloud Storage', '#1A73E8', 'Google storage for Drive, Gmail and Photos.',
  'Storage plans can be shared with up to 5 other people in a Google family group. Each person keeps their own private files.',
  'Check the current 2 TB price in the Google One app.', true, 10),
 ('Duolingo', 'Education', '#58CC02', 'Learn languages.',
  'Super Family: the owner plus up to 5 members, each with their own Duolingo account.',
  'Check the current Super Family price in the Duolingo app.', true, 11),
 ('ChatGPT', 'AI', '#10A37F', 'AI assistant by OpenAI.',
  'ChatGPT Plus is for one person. OpenAI does not allow sharing an account. Business/Team plans are billed per seat.',
  'Kept OFF: personal subscription. Do not enable account sharing.', false, 12),
 ('Claude', 'AI', '#D97757', 'AI assistant by Anthropic.',
  'Claude Pro is for one person. Anthropic does not allow sharing an account. Team plans are billed per seat.',
  'Kept OFF: personal subscription. Do not enable account sharing.', false, 13),
 ('MTN Data Share', 'Data', '#FFCC00', 'Mobile data shared to your MTN number.',
  'The host buys a large MTN bundle and sends each member their share of data with MTN Data Share. Members get data on their own line, not a login.',
  'Check current MTN bundle prices before going live.', true, 14)
on conflict (name) do nothing;

-- Plans: (service, plan, normal price kobo, compare price kobo or null, max seats, access, days, min %, max %, proof, customer instructions, host instructions)
insert into public.service_plans (service_id, name, normal_price_kobo, compare_price_kobo, max_seats, access_type, duration_days,
  min_markup_pct, max_markup_pct, verification_required, host_proof_required, active, customer_instructions, host_instructions, sort)
select s.id, v.plan, v.normal, v.compare, v.seats, v.access, 30, 10, 30, true, true, v.active, v.cust, v.host, 1
from (values
 ('Netflix', 'Premium', 850000, null::bigint, 4, 'LOGIN', true,
  'Use only the profile with your name on it. Do not change the password, the PIN or other profiles.',
  'Create one profile per member, named after them. Keep the plan on Premium for the whole period.'),
 ('YouTube Premium', 'Family', 360000, null, 5, 'FAMILY', true,
  'You will get a family invite at the email you gave. Accept it from the same Google account.',
  'Send the family invite from YouTube settings to the member''s email, then mark it as sent.'),
 ('Prime Video', 'Standard', 470000, null, 3, 'LOGIN', true,
  'Use only your own profile. Do not change the password.',
  'Create one profile per member, named after them.'),
 ('Disney+', 'Premium', 700000, null, 3, 'LOGIN', false, '', ''),
 ('Spotify', 'Premium Family', 250000, null, 5, 'FAMILY', true,
  'You will get a Spotify Family invite at the email you gave. Accept it with your own Spotify account.',
  'Invite the member from your Spotify account page, then mark it as sent.'),
 ('Apple Music', 'Family', 250000, null, 5, 'FAMILY', true,
  'You will get a Family Sharing invite at your Apple ID email. Accept it on your device.',
  'Invite the member in Settings > Family on your Apple device, then mark it as sent.'),
 ('Microsoft 365', 'Family', 800000, null, 5, 'FAMILY', true,
  'You will get an invite at your Microsoft account email. Accept it to get Office apps and 1 TB.',
  'Share the subscription from account.microsoft.com > Sharing, then mark it as sent.'),
 ('Canva', 'Teams', 1500000, null, 4, 'TEAM', false, '', ''),
 ('CapCut', 'Pro', 800000, null, 2, 'LOGIN', false, '', ''),
 ('Google One', '2 TB', 600000, null, 5, 'FAMILY', true,
  'You will get a Google family invite at your Gmail address. Accept it to use the shared storage.',
  'Invite the member to your Google family group, then mark it as sent.'),
 ('Duolingo', 'Super Family', 500000, null, 5, 'FAMILY', true,
  'You will get a Duolingo family invite. Accept it from your own Duolingo account.',
  'Invite the member from the Super Family screen, then mark it as sent.'),
 ('ChatGPT', 'Plus', 3000000, null, 2, 'LOGIN', false, '', ''),
 ('Claude', 'Pro', 3000000, null, 2, 'LOGIN', false, '', ''),
 ('MTN Data Share', '10GB each (100GB pool)', 2500000, 450000, 10, 'DATA', true,
  'Your data is sent to the MTN number you gave. You will get an SMS from MTN.',
  'Share 10GB to the member''s number with MTN Data Share, then mark it as sent.')
) as v(service, plan, normal, compare, seats, access, active, cust, host)
join public.services s on s.name = v.service
where not exists (select 1 from public.service_plans p where p.service_id = s.id and p.name = v.plan);
