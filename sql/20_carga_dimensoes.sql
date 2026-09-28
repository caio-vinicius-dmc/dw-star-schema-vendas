-- Carga das dimensões.
--
-- Cada bloco e independente e pode rodar quantas vezes for preciso: a
-- segunda execução não duplica nada. Para dim_cliente isso exige um pouco
-- mais de cuidado, porque a regra do SCD2 e "só cria versão nova quando
-- algum atributo monitorado realmente mudou".

-- ---------------------------------------------------------------------------
-- dim_data
-- ---------------------------------------------------------------------------
-- Gerada, não extraida. A dimensão de data cobre todo o período possível,
-- inclusive dias sem venda -- do contrário um gráfico de série temporal
-- ficaria com buracos em vez de zeros.
INSERT INTO dw.dim_data (
    sk_data, data, ano, trimestre, mes, dia, ano_mes,
    nome_mes, nome_mes_curto, dia_semana, nome_dia, fim_de_semana, semana_do_ano
)
SELECT
    (to_char(d, 'YYYYMMDD'))::int,
    d::date,
    extract(year    FROM d)::smallint,
    extract(quarter FROM d)::smallint,
    extract(month   FROM d)::smallint,
    extract(day     FROM d)::smallint,
    to_char(d, 'YYYY-MM'),
    (ARRAY['Janeiro','Fevereiro','Marco','Abril','Maio','Junho','Julho',
           'Agosto','Setembro','Outubro','Novembro','Dezembro'])
        [extract(month FROM d)::int],
    (ARRAY['Jan','Fev','Mar','Abr','Mai','Jun','Jul',
           'Ago','Set','Out','Nov','Dez'])[extract(month FROM d)::int],
    extract(isodow FROM d)::smallint,
    (ARRAY['Segunda','Terca','Quarta','Quinta','Sexta','Sabado','Domingo'])
        [extract(isodow FROM d)::int],
    extract(isodow FROM d) >= 6,
    extract(week FROM d)::smallint
FROM generate_series(DATE '2023-01-01', DATE '2026-12-31', INTERVAL '1 day') AS d
ON CONFLICT (sk_data) DO NOTHING;

-- ---------------------------------------------------------------------------
-- dim_produto e dim_loja: SCD tipo 1 (sobrescreve)
-- ---------------------------------------------------------------------------
INSERT INTO dw.dim_produto (id_produto, sku, nome, categoria, subcategoria,
                            marca, preco_lista, custo)
SELECT id, sku, nome, categoria, subcategoria, marca, preco_lista, custo
FROM origem.produto
ON CONFLICT (id_produto) DO UPDATE
    SET sku           = EXCLUDED.sku,
        nome          = EXCLUDED.nome,
        categoria     = EXCLUDED.categoria,
        subcategoria  = EXCLUDED.subcategoria,
        marca         = EXCLUDED.marca,
        preco_lista   = EXCLUDED.preco_lista,
        custo         = EXCLUDED.custo,
        atualizado_em = now();

INSERT INTO dw.dim_loja (id_loja, codigo, nome, cidade, uf, regiao, tipo)
SELECT id, codigo, nome, cidade, uf, regiao, tipo
FROM origem.loja
ON CONFLICT (id_loja) DO UPDATE
    SET codigo        = EXCLUDED.codigo,
        nome          = EXCLUDED.nome,
        cidade        = EXCLUDED.cidade,
        uf            = EXCLUDED.uf,
        regiao        = EXCLUDED.regiao,
        tipo          = EXCLUDED.tipo,
        atualizado_em = now();

-- ---------------------------------------------------------------------------
-- dim_cliente: SCD tipo 2 (versiona)
-- ---------------------------------------------------------------------------
-- São três passos, nesta ordem. Inverter a ordem do fechamento com a
-- inserção criaria, por um instante, duas versões vigentes do mesmo
-- cliente -- e o índice único parcial rejeitaria a carga inteira.

-- Passo 1: quem mudou. Comparar atributo a atributo evita fechar e reabrir
-- a versão de clientes que não mudaram nada, o que inflaria a dimensão a
-- cada execução.
CREATE TEMP TABLE clientes_alterados ON COMMIT DROP AS
SELECT o.id, o.nome, o.cidade, o.uf, o.segmento
FROM origem.cliente o
JOIN dw.dim_cliente d
  ON d.id_cliente = o.id
 AND d.vigente
WHERE (o.nome, o.cidade, o.uf, o.segmento)
   IS DISTINCT FROM (d.nome, d.cidade, d.uf, d.segmento);

-- Passo 2: fecha a versão antiga de quem mudou.
UPDATE dw.dim_cliente d
   SET vigente    = false,
       valido_ate = CURRENT_DATE - 1
  FROM clientes_alterados a
 WHERE d.id_cliente = a.id
   AND d.vigente;

-- Passo 3: abre a versão nova de quem mudou e insere quem e novo na base.
INSERT INTO dw.dim_cliente (id_cliente, nome, cidade, uf, segmento,
                            valido_de, versao)
SELECT
    a.id, a.nome, a.cidade, a.uf, a.segmento,
    CURRENT_DATE,
    coalesce((SELECT max(versao) FROM dw.dim_cliente v WHERE v.id_cliente = a.id), 0) + 1
FROM clientes_alterados a;

INSERT INTO dw.dim_cliente (id_cliente, nome, cidade, uf, segmento, valido_de)
SELECT o.id, o.nome, o.cidade, o.uf, o.segmento, o.cadastrado_em
FROM origem.cliente o
WHERE NOT EXISTS (
    SELECT 1 FROM dw.dim_cliente d WHERE d.id_cliente = o.id
);

ANALYZE dw.dim_data;
ANALYZE dw.dim_cliente;
ANALYZE dw.dim_produto;
ANALYZE dw.dim_loja;
