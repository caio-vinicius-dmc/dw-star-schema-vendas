-- Popula a base transacional simulada.
--
-- Marcadores trocados pelo carregador: {qtd_clientes}, {qtd_produtos},
-- {qtd_pedidos}. São inteiros vindos da configuração, nunca entrada de
-- usuário.

SELECT setseed(0.31);

TRUNCATE origem.item_pedido, origem.pedido, origem.produto,
         origem.cliente, origem.loja RESTART IDENTITY CASCADE;

-- ---------------------------------------------------------------------------
-- Lojas
-- ---------------------------------------------------------------------------
INSERT INTO origem.loja (id, codigo, nome, cidade, uf, regiao, tipo)
SELECT
    g,
    'LJ' || lpad(g::text, 3, '0'),
    'Loja ' || (ARRAY['Centro','Shopping Norte','Shopping Sul','Aeroporto',
                      'Bairro Alto','Marginal','Praca Central','Terminal',
                      'Avenida','Litoral'])[1 + (g % 10)],
    cidades.cidade,
    cidades.uf,
    cidades.regiao,
    CASE WHEN g % 7 = 0 THEN 'online' ELSE 'fisica' END
FROM generate_series(1, 20) AS g
CROSS JOIN LATERAL (
    SELECT
        (ARRAY['São Paulo','Campinas','Rio de Janeiro','Belo Horizonte',
               'Curitiba','Porto Alegre','Salvador','Recife','Fortaleza',
               'Goiânia'])[1 + (g % 10)] AS cidade,
        (ARRAY['SP','SP','RJ','MG','PR','RS','BA','PE','CE','GO'])[1 + (g % 10)] AS uf,
        (ARRAY['Sudeste','Sudeste','Sudeste','Sudeste','Sul','Sul',
               'Nordeste','Nordeste','Nordeste','Centro-Oeste'])[1 + (g % 10)] AS regiao
) AS cidades;

-- ---------------------------------------------------------------------------
-- Clientes
-- ---------------------------------------------------------------------------
INSERT INTO origem.cliente (id, nome, cidade, uf, segmento, cadastrado_em)
SELECT
    g,
    'Cliente ' || g,
    (ARRAY['São Paulo','Campinas','Rio de Janeiro','Belo Horizonte','Curitiba',
           'Porto Alegre','Salvador','Recife','Fortaleza','Goiânia'])[1 + (g % 10)],
    (ARRAY['SP','SP','RJ','MG','PR','RS','BA','PE','CE','GO'])[1 + (g % 10)],
    -- Distribuição desigual: a maior parte da base é Varejo, e o segmento
    -- Corporativo, pequeno, concentra ticket alto. É o que torna os cortes
    -- por segmento interessantes no relatório.
    CASE
        WHEN random() < 0.62 THEN 'Varejo'
        WHEN random() < 0.85 THEN 'Recorrente'
        WHEN random() < 0.96 THEN 'Corporativo'
        ELSE 'Atacado'
    END,
    -- O cadastro precisa ser anterior ao primeiro pedido possível
    -- (01/01/2024). Se um cliente pudesse comprar antes de existir, a
    -- junção do fato com a dimensão versionada não acharia versão valida
    -- para aquela data e a linha sumiria da carga -- silenciosamente.
    DATE '2022-01-01' + (random() * 729)::int
FROM generate_series(1, {qtd_clientes}) AS g;

-- ---------------------------------------------------------------------------
-- Produtos
-- ---------------------------------------------------------------------------
INSERT INTO origem.produto (id, sku, nome, categoria, subcategoria, marca,
                            preco_lista, custo)
SELECT
    g,
    'SKU-' || lpad(g::text, 5, '0'),
    cat.categoria || ' ' || cat.subcategoria || ' ' || g,
    cat.categoria,
    cat.subcategoria,
    (ARRAY['Aurora','Bravo','Cedro','Delta','Everest','Ferro',
           'Gaia','Horizonte'])[1 + (g % 8)],
    preco.valor,
    -- margem bruta entre 22% e 48%, variando por produto
    round((preco.valor * (0.52 + random() * 0.26))::numeric, 2)
FROM generate_series(1, {qtd_produtos}) AS g
CROSS JOIN LATERAL (
    SELECT
        (ARRAY['Eletrônicos','Eletrônicos','Casa','Casa','Moda','Moda',
               'Esporte','Livros'])[1 + (g % 8)] AS categoria,
        (ARRAY['Áudio','Informática','Cozinha','Decoração','Calçados',
               'Vestuário','Fitness','Ficção'])[1 + (g % 8)] AS subcategoria
) AS cat
CROSS JOIN LATERAL (
    SELECT round((random() * 780 + 25)::numeric, 2) AS valor
) AS preco;

-- ---------------------------------------------------------------------------
-- Pedidos e itens
-- ---------------------------------------------------------------------------
INSERT INTO origem.pedido (id, cliente_id, loja_id, criado_em, status)
SELECT
    g,
    1 + (random() * ({qtd_clientes} - 1))::int,
    1 + (random() * 19)::int,
    -- Dois anos de histórico. O expoente 0.85 concentra um pouco mais os
    -- pedidos no período recente, criando tendência de crescimento.
    TIMESTAMPTZ '2024-01-01'
        + (729 * power(random(), 0.85))::int * INTERVAL '1 day'
        + (random() * 86399)::int * INTERVAL '1 second',
    CASE
        WHEN random() < 0.02 THEN 'cancelado'
        WHEN random() < 0.06 THEN 'pendente'
        ELSE 'faturado'
    END
FROM generate_series(1, {qtd_pedidos}) AS g;

-- O número de itens vem de p.id, e não de random(): dentro de um LATERAL o
-- planejador pode avaliar a função volátil uma única vez e todos os pedidos
-- sairiam com o mesmo tamanho.
WITH itens AS (
    SELECT
        p.id AS pedido_id,
        n    AS numero_item,
        -- O expoente concentra as vendas nos produtos de id baixo. Sem
        -- isso todos os 600 produtos venderiam igual e um relatório de
        -- "top produtos" não teria topo nenhum.
        1 + (({qtd_produtos} - 1) * power(random(), 2.2))::int AS produto_id,
        1 + (random() * 3)::int                                AS quantidade,
        random()                                               AS sorteio_desconto
    FROM origem.pedido p
    CROSS JOIN LATERAL generate_series(1, 1 + (p.id % 4)) AS n
)
INSERT INTO origem.item_pedido (id, pedido_id, produto_id, numero_item,
                                quantidade, preco_unitario, desconto)
SELECT
    row_number() OVER (),
    i.pedido_id,
    i.produto_id,
    i.numero_item,
    i.quantidade,
    pr.preco_lista,
    -- Desconto em 30% dos itens, de até 18% do valor de lista.
    CASE WHEN i.sorteio_desconto < 0.30
         THEN round((pr.preco_lista * i.sorteio_desconto * 0.6)::numeric, 2)
         ELSE 0 END
FROM itens i
JOIN origem.produto pr ON pr.id = i.produto_id;

ANALYZE origem.cliente;
ANALYZE origem.produto;
ANALYZE origem.loja;
ANALYZE origem.pedido;
ANALYZE origem.item_pedido;
