-- =====================================================================================================
-- ZecaMotos - complete database schema (PostgreSQL / Supabase)
-- Run once in the Supabase SQL Editor on an EMPTY project. Safe to re-run (idempotent).
-- Requires the Supabase "auth" schema (auth.users, auth.uid(), auth.jwt()) and the roles anon/authenticated.
-- Business rules live in the database (PL/pgSQL functions); access control is Row Level Security (RLS).
-- User-facing error messages are in Portuguese on purpose (the app is used by a Brazilian shop).
-- =====================================================================================================

-- ----------------------------------------------------------------------------------------------
-- 1. TABLES
-- ----------------------------------------------------------------------------------------------

create table if not exists products (
  id         bigint generated always as identity primary key,
  code       text,                                      -- P0001... (auto) or typed by the user
  name       text not null,
  category   text,
  cost_price numeric(10,2) not null default 0,          -- weighted average cost
  sale_price numeric(10,2) not null default 0,
  stock      integer not null default 0 check (stock >= 0),
  min_stock  integer not null default 5,                -- low-stock alert threshold (does not block sales)
  active     boolean not null default true,             -- false = archived (soft delete)
  created_at timestamptz not null default now()
);

create table if not exists services (
  id         bigint generated always as identity primary key,
  code       text,                                      -- S0001... (auto) or typed by the user
  name       text not null,
  category   text,
  price      numeric(10,2) not null default 0,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists clients (
  id         bigint generated always as identity primary key,
  name       text not null,
  phone      text,
  motorcycle text,                                      -- model
  plate      text,                                      -- optional, always stored in UPPER CASE (trigger)
  address    text,                                      -- optional marketing data
  gender     text check (gender in ('Homem', 'Mulher', 'Outro')),
  age_range  text check (age_range in ('Menos de 20', '20 a 29', '30 a 39', '40 a 49', '50 a 59', '60 a 69', '70 ou mais')),
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists sales (
  id          bigint generated always as identity primary key,
  numero      bigint generated always as identity,      -- human-friendly receipt number
  created_at  timestamptz not null default now(),
  customer    text,
  motorcycle  text,
  plate       text,
  km          integer check (km >= 0),                  -- odometer at service time
  payment     text,                                     -- Dinheiro | Pix | Cartão de débito | Cartão de crédito | Fiado
  -- Line-item snapshot: [{type, id, code, name, qty, price, paid(cost)}].
  -- Stored as JSONB so historical revenue/profit never change when prices or costs change later.
  items       jsonb not null default '[]',
  total       numeric(10,2) not null default 0,
  paid        numeric(10,2) not null default 0,         -- amount already received (relevant for "Fiado")
  status      text not null default 'ativa' check (status in ('ativa', 'cancelada')),
  canceled_at timestamptz,
  client_id   bigint references clients(id)
);

create table if not exists payments (                    -- receipts of "Fiado" (credit) sales
  id         bigint generated always as identity primary key,
  sale_id    bigint not null references sales(id),
  amount     numeric(10,2) not null check (amount > 0),
  method     text,
  user_email text,
  created_at timestamptz not null default now()
);

create table if not exists purchases (                   -- stock purchases
  id           bigint generated always as identity primary key,
  created_at   timestamptz not null default now(),
  product_id   bigint references products(id),
  product_name text,
  qty          integer not null check (qty > 0),
  unit_cost    numeric(10,2) not null check (unit_cost >= 0),
  supplier     text,
  user_email   text
);

create table if not exists appointments (                -- service calendar
  id           bigint generated always as identity primary key,
  scheduled_at timestamptz not null,
  client_id    bigint references clients(id),
  customer     text not null,
  motorcycle   text,
  plate        text,
  service      text,
  notes        text,
  status       text not null default 'agendado' check (status in ('agendado', 'concluido', 'cancelado')),
  created_by   text,
  created_at   timestamptz not null default now()
);

create table if not exists profiles (                    -- access level of each Supabase Auth user
  id         uuid primary key references auth.users(id) on delete cascade,
  email      text,
  role       text not null default 'funcionario' check (role in ('admin', 'funcionario')),
  created_at timestamptz not null default now()
);

create table if not exists audit_log (                   -- who did what, and when
  id         bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  user_email text,
  action     text,
  table_name text,
  details    jsonb
);

-- ----------------------------------------------------------------------------------------------
-- 2. INDEXES AND SEQUENCES
-- ----------------------------------------------------------------------------------------------

create sequence if not exists product_code_seq;
create sequence if not exists service_code_seq;

create unique index if not exists products_code_key      on products (code);
create unique index if not exists services_code_key      on services (code);
create index        if not exists sales_created_idx      on sales (created_at desc);
create index        if not exists sales_client_idx       on sales (client_id);
create index        if not exists sales_fiado_idx        on sales (created_at) where payment = 'Fiado' and status = 'ativa';
create index        if not exists payments_sale_idx      on payments (sale_id);
create index        if not exists purchases_product_idx  on purchases (product_id);
create index        if not exists appointments_when_idx  on appointments (scheduled_at);

-- ----------------------------------------------------------------------------------------------
-- 3. HELPER FUNCTIONS AND TRIGGERS
-- ----------------------------------------------------------------------------------------------

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from profiles where id = auth.uid() and role = 'admin') $$;

-- empty code => auto-generated (P0001 / S0001); typed code => normalized to upper case
create or replace function set_code() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.code is null or trim(new.code) = '' then
    new.code := case tg_table_name
      when 'products' then 'P' || lpad(nextval('product_code_seq')::text, 4, '0')
      else 'S' || lpad(nextval('service_code_seq')::text, 4, '0') end;
  else
    new.code := upper(trim(new.code));
  end if;
  return new;
end $$;

-- license plates are always stored in upper case
create or replace function upper_plate() returns trigger language plpgsql as $$
begin
  new.plate := nullif(upper(trim(coalesce(new.plate, ''))), '');
  return new;
end $$;

-- generic audit trigger: stores old/new row as JSON
create or replace function log_change() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into audit_log (user_email, action, table_name, details) values (
    auth.jwt() ->> 'email', tg_op, tg_table_name,
    case when tg_op = 'DELETE' then to_jsonb(old)
         else jsonb_build_object('novo', to_jsonb(new), 'antigo', case when tg_op = 'UPDATE' then to_jsonb(old) end) end);
  return coalesce(new, old);
end $$;

drop trigger if exists t_prod_code on products;
drop trigger if exists t_serv_code on services;
create trigger t_prod_code before insert or update of code on products for each row execute function set_code();
create trigger t_serv_code before insert or update of code on services for each row execute function set_code();

drop trigger if exists t_plate on clients;
drop trigger if exists t_plate on sales;
drop trigger if exists t_plate on appointments;
create trigger t_plate before insert or update of plate on clients      for each row execute function upper_plate();
create trigger t_plate before insert or update of plate on sales        for each row execute function upper_plate();
create trigger t_plate before insert or update of plate on appointments for each row execute function upper_plate();

-- audit: only meaningful changes are logged (stock movements from sales are NOT logged here)
drop trigger if exists t_prod_ins on products;
drop trigger if exists t_prod_upd on products;
drop trigger if exists t_prod_del on products;
create trigger t_prod_ins after insert on products for each row execute function log_change();
create trigger t_prod_del after delete on products for each row execute function log_change();
create trigger t_prod_upd after update on products for each row
  when (old.name is distinct from new.name or old.cost_price is distinct from new.cost_price
     or old.sale_price is distinct from new.sale_price or old.min_stock is distinct from new.min_stock
     or old.active is distinct from new.active or old.code is distinct from new.code
     or old.category is distinct from new.category) execute function log_change();

drop trigger if exists t_serv_ins on services;
drop trigger if exists t_serv_upd on services;
drop trigger if exists t_serv_del on services;
create trigger t_serv_ins after insert on services for each row execute function log_change();
create trigger t_serv_del after delete on services for each row execute function log_change();
create trigger t_serv_upd after update on services for each row
  when (old.name is distinct from new.name or old.price is distinct from new.price
     or old.active is distinct from new.active or old.code is distinct from new.code
     or old.category is distinct from new.category) execute function log_change();

drop trigger if exists t_cli_ins on clients;
drop trigger if exists t_cli_upd on clients;
create trigger t_cli_ins after insert on clients for each row execute function log_change();
create trigger t_cli_upd after update on clients for each row
  when (old.name is distinct from new.name or old.phone is distinct from new.phone
     or old.motorcycle is distinct from new.motorcycle or old.plate is distinct from new.plate
     or old.address is distinct from new.address or old.gender is distinct from new.gender
     or old.age_range is distinct from new.age_range or old.active is distinct from new.active)
  execute function log_change();

-- ----------------------------------------------------------------------------------------------
-- 4. VIEW WITHOUT COST (what staff users are allowed to read)
-- ----------------------------------------------------------------------------------------------

create or replace view products_pub as
  select id, code, name, category, sale_price, stock, min_stock, active from products;

-- ----------------------------------------------------------------------------------------------
-- 5. BUSINESS FUNCTIONS (called through the API as RPC; each one runs in a single transaction)
-- ----------------------------------------------------------------------------------------------

-- Sale + stock decrement + audit in ONE transaction. Stock can never go negative.
-- Staff users always get catalog prices and never receive cost data back; credit sales are admin-only.
create or replace function create_sale(p_customer text, p_motorcycle text, p_payment text, p_items jsonb,
                                       p_client_id bigint default null, p_plate text default null, p_km integer default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  it jsonb; r jsonb; itens jsonb := '[]'::jsonb; v_total numeric := 0; s sales; v jsonb;
  adm boolean := is_admin(); pr products; sv services; v_qty int; v_price numeric;
begin
  if auth.uid() is null then raise exception 'Faça login novamente.'; end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then raise exception 'Venda sem itens.'; end if;
  if p_payment = 'Fiado' and not adm then raise exception 'Só o administrador pode vender no fiado.'; end if;
  if p_payment = 'Fiado' and p_client_id is null then raise exception 'Escolha um cliente cadastrado para vender no fiado.'; end if;
  if p_km is not null and p_km < 0 then raise exception 'Quilometragem inválida.'; end if;

  for it in select value from jsonb_array_elements(p_items) loop
    v_qty := (it->>'qty')::int;
    if v_qty < 1 then raise exception 'Item inválido.'; end if;
    if it->>'type' = 'product' then
      select * into pr from products where id = (it->>'id')::bigint;
      if not found then raise exception 'Produto não encontrado: %', it->>'name'; end if;
      update products set stock = stock - v_qty where id = pr.id and stock >= v_qty;
      if not found then raise exception 'Estoque insuficiente: %', pr.name; end if;
      if adm then v_price := (it->>'price')::numeric; else v_price := pr.sale_price; end if;
      r := jsonb_build_object('type', 'product', 'id', pr.id, 'code', pr.code, 'name', pr.name, 'qty', v_qty, 'paid', pr.cost_price, 'price', v_price);
    else
      if adm then
        v_price := (it->>'price')::numeric;
        r := jsonb_build_object('type', 'service', 'id', coalesce((it->>'id')::bigint, 0), 'code', it->>'code', 'name', it->>'name', 'qty', v_qty, 'paid', null, 'price', v_price);
      else
        select * into sv from services where id = (it->>'id')::bigint;
        if not found then raise exception 'Serviço não encontrado: %', it->>'name'; end if;
        v_price := sv.price;
        r := jsonb_build_object('type', 'service', 'id', sv.id, 'code', sv.code, 'name', sv.name, 'qty', v_qty, 'paid', null, 'price', v_price);
      end if;
    end if;
    if v_price < 0 then raise exception 'Item inválido.'; end if;
    itens := itens || jsonb_build_array(r);
    v_total := v_total + v_price * v_qty;
  end loop;

  insert into sales (customer, motorcycle, plate, km, payment, items, total, client_id, paid)
  values (left(coalesce(p_customer,''),120), left(coalesce(p_motorcycle,''),120), p_plate, p_km,
          left(coalesce(p_payment,''),40), itens, v_total, p_client_id, case when p_payment = 'Fiado' then 0 else v_total end)
  returning * into s;
  insert into audit_log (user_email, action, table_name, details)
  values (auth.jwt() ->> 'email', 'VENDA', 'sales', jsonb_build_object('numero', s.numero, 'total', s.total, 'pagamento', s.payment));

  v := to_jsonb(s);
  if not adm then   -- staff never gets cost data back
    v := jsonb_set(v, '{items}', coalesce((select jsonb_agg(i - 'paid') from jsonb_array_elements(s.items) i), '[]'::jsonb));
  end if;
  return v;
end $$;

-- Cancel a sale: stock goes back, the record stays (status = 'cancelada'). Admin only.
create or replace function cancel_sale(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare s sales; it jsonb;
begin
  if not is_admin() then raise exception 'Só o administrador pode cancelar vendas.'; end if;
  select * into s from sales where id = p_id for update;
  if not found then raise exception 'Venda não encontrada.'; end if;
  if s.status <> 'ativa' then raise exception 'Esta venda já foi cancelada.'; end if;
  for it in select value from jsonb_array_elements(s.items) loop
    if it->>'type' = 'product' then
      update products set stock = stock + (it->>'qty')::int where id = (it->>'id')::bigint;
    end if;
  end loop;
  update sales set status = 'cancelada', canceled_at = now() where id = p_id;
  insert into audit_log (user_email, action, table_name, details)
  values (auth.jwt() ->> 'email', 'CANCELAR', 'sales', jsonb_build_object('numero', s.numero, 'total', s.total));
end $$;

-- Receive (part of) a credit sale. Admin only.
create or replace function receive_payment(p_sale bigint, p_amount numeric, p_method text)
returns void language plpgsql security definer set search_path = public as $$
declare s sales;
begin
  if not is_admin() then raise exception 'Só o administrador pode registrar recebimentos.'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Valor inválido.'; end if;
  select * into s from sales where id = p_sale for update;
  if not found or s.status <> 'ativa' then raise exception 'Venda não encontrada ou cancelada.'; end if;
  if p_amount > (s.total - s.paid) + 0.004 then
    raise exception 'O valor é maior do que falta receber (R$ %).', (s.total - s.paid);
  end if;
  update sales set paid = least(total, paid + p_amount) where id = p_sale;
  insert into payments (sale_id, amount, method, user_email) values (p_sale, p_amount, left(coalesce(p_method,''),40), auth.jwt() ->> 'email');
  insert into audit_log (user_email, action, table_name, details)
  values (auth.jwt() ->> 'email', 'RECEBIMENTO', 'sales', jsonb_build_object('numero', s.numero, 'valor', p_amount));
end $$;

-- Register an old debt that did not come from a sale made in the system. Admin only.
create or replace function add_debt(p_client_id bigint, p_description text, p_amount numeric, p_date date default null)
returns sales language plpgsql security definer set search_path = public as $$
declare c clients; s sales;
begin
  if not is_admin() then raise exception 'Só o administrador pode registrar dívidas.'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Valor inválido.'; end if;
  select * into c from clients where id = p_client_id;
  if not found then raise exception 'Cliente não encontrado.'; end if;
  insert into sales (customer, motorcycle, plate, payment, items, total, client_id, paid, created_at)
  values (c.name, coalesce(c.motorcycle, ''), c.plate, 'Fiado',
          jsonb_build_array(jsonb_build_object('type', 'service', 'id', 0,
            'name', left(coalesce(nullif(trim(p_description), ''), 'Dívida anterior'), 200),
            'qty', 1, 'paid', null, 'price', p_amount)),
          p_amount, p_client_id, 0,
          coalesce((p_date + time '12:00') at time zone 'America/Sao_Paulo', now()))
  returning * into s;
  insert into audit_log (user_email, action, table_name, details)
  values (auth.jwt() ->> 'email', 'DIVIDA', 'sales', jsonb_build_object('numero', s.numero, 'cliente', c.name, 'valor', p_amount));
  return s;
end $$;

-- Edit value/description of a manually registered debt. Admin only.
create or replace function edit_debt(p_sale bigint, p_total numeric, p_description text)
returns void language plpgsql security definer set search_path = public as $$
declare s sales; manual boolean;
begin
  if not is_admin() then raise exception 'Só o administrador pode editar dívidas.'; end if;
  select * into s from sales where id = p_sale for update;
  if not found or s.payment <> 'Fiado' or s.status <> 'ativa' then raise exception 'Dívida não encontrada.'; end if;
  manual := jsonb_array_length(s.items) = 1 and (s.items->0->>'id') = '0';
  if not manual then
    raise exception 'Esta dívida vem de uma venda com itens. Para mudar o valor, cancele a venda e refaça.';
  end if;
  if p_total is null or p_total <= 0 then raise exception 'Valor inválido.'; end if;
  if p_total < s.paid then raise exception 'O valor não pode ser menor do que já foi pago (R$ %).', s.paid; end if;
  update sales set total = p_total,
    items = jsonb_build_array(jsonb_set(jsonb_set(s.items->0, '{price}', to_jsonb(p_total)),
            '{name}', to_jsonb(left(coalesce(nullif(trim(p_description), ''), 'Dívida anterior'), 200))))
   where id = p_sale;
  insert into audit_log (user_email, action, table_name, details)
  values (auth.jwt() ->> 'email', 'EDITAR DIVIDA', 'sales',
          jsonb_build_object('numero', s.numero, 'valor_antigo', s.total, 'valor_novo', p_total));
end $$;

-- Stock purchase: adds stock and recomputes the WEIGHTED AVERAGE COST.
--   10 units @ R$ 5.00 in stock + purchase of 10 units @ R$ 7.00  =>  average cost R$ 6.00
create or replace function register_purchase(p_product bigint, p_qty integer, p_unit_cost numeric,
                                             p_supplier text default null, p_new_price numeric default null)
returns void language plpgsql security definer set search_path = public as $$
declare pr products; v_cost numeric;
begin
  if not is_admin() then raise exception 'Só o administrador pode registrar compras.'; end if;
  if p_qty is null or p_qty < 1 then raise exception 'Quantidade inválida.'; end if;
  if p_unit_cost is null or p_unit_cost < 0 then raise exception 'Custo inválido.'; end if;
  if p_new_price is not null and p_new_price < 0 then raise exception 'Preço de venda inválido.'; end if;
  select * into pr from products where id = p_product for update;
  if not found then raise exception 'Produto não encontrado.'; end if;

  if pr.stock > 0 then
    v_cost := round((pr.stock * pr.cost_price + p_qty * p_unit_cost) / (pr.stock + p_qty), 2);
  else
    v_cost := p_unit_cost;   -- no stock left: the purchase cost is the cost
  end if;

  update products set stock = stock + p_qty, cost_price = v_cost, sale_price = coalesce(p_new_price, sale_price)
   where id = p_product;
  insert into purchases (product_id, product_name, qty, unit_cost, supplier, user_email)
  values (p_product, pr.name, p_qty, p_unit_cost, nullif(trim(coalesce(p_supplier, '')), ''), auth.jwt() ->> 'email');
  insert into audit_log (user_email, action, table_name, details)
  values (auth.jwt() ->> 'email', 'COMPRA', 'products',
          jsonb_build_object('produto', pr.name, 'qtd', p_qty, 'custo_compra', p_unit_cost, 'custo_medio_antigo', pr.cost_price, 'custo_medio_novo', v_cost));
end $$;

-- ----------------------------------------------------------------------------------------------
-- 6. SECURITY: ROW LEVEL SECURITY + GRANTS
--    anon (not logged in) gets nothing. Staff gets the minimum. Admin gets everything.
-- ----------------------------------------------------------------------------------------------

alter table products     enable row level security;
alter table services     enable row level security;
alter table clients      enable row level security;
alter table sales        enable row level security;
alter table payments     enable row level security;
alter table purchases    enable row level security;
alter table appointments enable row level security;
alter table profiles     enable row level security;
alter table audit_log    enable row level security;

revoke all on products, services, clients, sales, payments, purchases, appointments, profiles, audit_log, products_pub from anon;
grant  select on products_pub to authenticated;

-- products: only admin reads the base table (it holds costs). Staff reads the view products_pub.
drop policy if exists "admin produtos" on products;
create policy "admin produtos" on products for all to authenticated using (is_admin()) with check (is_admin());

-- services: everyone reads, admin writes
drop policy if exists "ver servicos"   on services;
drop policy if exists "admin servicos" on services;
create policy "ver servicos"   on services for select to authenticated using (true);
create policy "admin servicos" on services for all    to authenticated using (is_admin()) with check (is_admin());

-- clients: everyone reads and registers, only admin edits, nobody deletes (archive instead)
drop policy if exists "ver clientes"         on clients;
drop policy if exists "criar clientes"       on clients;
drop policy if exists "admin edita clientes" on clients;
create policy "ver clientes"         on clients for select to authenticated using (true);
create policy "criar clientes"       on clients for insert to authenticated with check (true);
create policy "admin edita clientes" on clients for update to authenticated using (is_admin()) with check (is_admin());
revoke delete on clients from authenticated;

-- sales, payments, purchases, audit_log: admin reads; writes ONLY through the functions above
drop policy if exists "admin vendas"     on sales;
drop policy if exists "admin pagamentos" on payments;
drop policy if exists "admin compras"    on purchases;
drop policy if exists "admin auditoria"  on audit_log;
create policy "admin vendas"     on sales     for select to authenticated using (is_admin());
create policy "admin pagamentos" on payments  for select to authenticated using (is_admin());
create policy "admin compras"    on purchases for select to authenticated using (is_admin());
create policy "admin auditoria"  on audit_log for select to authenticated using (is_admin());
revoke insert, update, delete on sales, payments, purchases, audit_log from authenticated;

-- appointments: everyone sees, schedules and updates status; only admin deletes
drop policy if exists "ver agenda"    on appointments;
drop policy if exists "criar agenda"  on appointments;
drop policy if exists "mudar agenda"  on appointments;
drop policy if exists "apagar agenda" on appointments;
create policy "ver agenda"    on appointments for select to authenticated using (true);
create policy "criar agenda"  on appointments for insert to authenticated with check (true);
create policy "mudar agenda"  on appointments for update to authenticated using (true) with check (true);
create policy "apagar agenda" on appointments for delete to authenticated using (is_admin());

-- profiles: each user sees their own row, admin sees and manages all
drop policy if exists "ver perfil"   on profiles;
drop policy if exists "admin perfis" on profiles;
create policy "ver perfil"   on profiles for select to authenticated using (id = auth.uid() or is_admin());
create policy "admin perfis" on profiles for all    to authenticated using (is_admin()) with check (is_admin());

-- who may call each business function
revoke execute on function create_sale(text, text, text, jsonb, bigint, text, integer) from public, anon;
revoke execute on function cancel_sale(bigint)                                          from public, anon;
revoke execute on function receive_payment(bigint, numeric, text)                       from public, anon;
revoke execute on function add_debt(bigint, text, numeric, date)                        from public, anon;
revoke execute on function edit_debt(bigint, numeric, text)                             from public, anon;
revoke execute on function register_purchase(bigint, integer, numeric, text, numeric)   from public, anon;
grant  execute on function create_sale(text, text, text, jsonb, bigint, text, integer)  to authenticated;
grant  execute on function cancel_sale(bigint)                                          to authenticated;
grant  execute on function receive_payment(bigint, numeric, text)                       to authenticated;
grant  execute on function add_debt(bigint, text, numeric, date)                        to authenticated;
grant  execute on function edit_debt(bigint, numeric, text)                             to authenticated;
grant  execute on function register_purchase(bigint, integer, numeric, text, numeric)   to authenticated;

-- ----------------------------------------------------------------------------------------------
-- 7. FIRST ADMIN (run AFTER creating your first user in Authentication > Users)
-- ----------------------------------------------------------------------------------------------
-- insert into profiles (id, email, role)
-- select id, email, 'admin' from auth.users where email = 'your-email@example.com'
-- on conflict (id) do update set role = 'admin';
