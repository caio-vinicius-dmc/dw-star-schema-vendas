-- Camada de consumo. É o que a ferramenta de BI enxerga: nomes em
-- portugues, sem chaves substitutas e sem precisar escrever junção.
--
-- Manter as views separadas do modelo permite mudar o físico (particionar,
-- renomear coluna, trocar o tipo de SCD) sem quebrar o relatório de
-- ninguém -- desde que a view continue devolvendo as mesmas colunas.

CREATE SCHEMA IF NOT EXISTS bi;

-- ---------------------------------------------------------------------------
-- View ampla: uma linha por item vendido, já com todos os atributos
-- ---------------------------------------------------------------------------
-- É a única que o Power BI precisa importar quando se quer o caminho mais
-- curto. Para modelos maiores vale importar as tabelas separadas e montar
-- o relacionamento lá dentro; o guia em docs/power-bi.md compara os dois.
CREATE OR REPLACE VIEW bi.vw_vendas AS
SELECT
    f.id_pedido,
    f.numero_item,

    d.data                          AS data_venda,
    d.ano,
    d.trimestre,
    d.ano_mes,
    d.nome_mes,
    d.nome_dia,
    d.fim_de_semana,

    c.id_cliente,
    c.nome                          AS cliente,
    c.cidade                        AS cliente_cidade,
    c.uf                            AS cliente_uf,
    c.segmento                      AS cliente_segmento,

    p.sku,
    p.nome                          AS produto,
    p.categoria,
    p.subcategoria,
    p.marca,

    l.codigo                        AS loja_codigo,
    l.nome                          AS loja,
    l.regiao                        AS loja_regiao,
    l.uf                            AS loja_uf,
    l.tipo                          AS loja_tipo,

    f.quantidade,
    f.valor_bruto,
    f.desconto,
    f.valor_liquido,
    f.custo_total,
    f.margem
FROM dw.fato_venda f
JOIN dw.dim_data    d ON d.sk_data    = f.sk_data
JOIN dw.dim_cliente c ON c.sk_cliente = f.sk_cliente
JOIN dw.dim_produto p ON p.sk_produto = f.sk_produto
JOIN dw.dim_loja    l ON l.sk_loja    = f.sk_loja;

-- ---------------------------------------------------------------------------
-- Agregados prontos
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW bi.vw_resumo_mensal AS
SELECT
    d.ano_mes,
    d.ano,
    d.mes,
    count(DISTINCT f.id_pedido)                 AS pedidos,
    sum(f.quantidade)                           AS itens,
    sum(f.valor_liquido)                        AS receita,
    sum(f.margem)                               AS margem,
    round(100 * sum(f.margem) / nullif(sum(f.valor_liquido), 0), 2) AS margem_pct,
    round(sum(f.valor_liquido) / nullif(count(DISTINCT f.id_pedido), 0), 2) AS ticket_medio
FROM dw.fato_venda f
JOIN dw.dim_data d ON d.sk_data = f.sk_data
GROUP BY d.ano_mes, d.ano, d.mes;

CREATE OR REPLACE VIEW bi.vw_margem_categoria AS
SELECT
    p.categoria,
    p.subcategoria,
    sum(f.quantidade)     AS itens,
    sum(f.valor_liquido)  AS receita,
    sum(f.custo_total)    AS custo,
    sum(f.margem)         AS margem,
    round(100 * sum(f.margem) / nullif(sum(f.valor_liquido), 0), 2) AS margem_pct
FROM dw.fato_venda f
JOIN dw.dim_produto p ON p.sk_produto = f.sk_produto
GROUP BY p.categoria, p.subcategoria;

CREATE OR REPLACE VIEW bi.vw_desempenho_loja AS
SELECT
    l.regiao,
    l.uf,
    l.nome                AS loja,
    l.tipo,
    count(DISTINCT f.id_pedido) AS pedidos,
    sum(f.valor_liquido)  AS receita,
    sum(f.margem)         AS margem,
    round(sum(f.valor_liquido) / nullif(count(DISTINCT f.id_pedido), 0), 2) AS ticket_medio
FROM dw.fato_venda f
JOIN dw.dim_loja l ON l.sk_loja = f.sk_loja
GROUP BY l.regiao, l.uf, l.nome, l.tipo;

-- ---------------------------------------------------------------------------
-- Histórico do cliente
-- ---------------------------------------------------------------------------
-- Existe para mostrar o SCD2 funcionando: quando um cliente troca de
-- segmento, as vendas antigas continuam no segmento antigo.
CREATE OR REPLACE VIEW bi.vw_historico_cliente AS
SELECT
    c.id_cliente,
    c.nome,
    c.versao,
    c.segmento,
    c.cidade,
    c.uf,
    c.valido_de,
    c.valido_ate,
    c.vigente,
    count(f.sk_venda)                    AS vendas_nesta_versao,
    coalesce(sum(f.valor_liquido), 0)    AS receita_nesta_versao
FROM dw.dim_cliente c
LEFT JOIN dw.fato_venda f ON f.sk_cliente = c.sk_cliente
GROUP BY c.id_cliente, c.nome, c.versao, c.segmento, c.cidade, c.uf,
         c.valido_de, c.valido_ate, c.vigente;
