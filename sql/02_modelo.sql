-- Modelo dimensional. Uma tabela fato no centro, dimensões ao redor, sem
-- floco de neve: categoria e subcategoria ficam dentro de dim_produto em
-- vez de virarem tabelas próprias.
--
-- A escolha e deliberada. Normalizar a hierarquia economizaria pouco
-- espaço e obrigaria a ferramenta de BI a fazer uma junção a mais em toda
-- consulta. Em modelo analítico a redundância controlada compensa.

CREATE SCHEMA IF NOT EXISTS dw;

DROP TABLE IF EXISTS dw.fato_venda CASCADE;
DROP TABLE IF EXISTS dw.dim_cliente CASCADE;
DROP TABLE IF EXISTS dw.dim_produto CASCADE;
DROP TABLE IF EXISTS dw.dim_loja CASCADE;
DROP TABLE IF EXISTS dw.dim_data CASCADE;

-- ---------------------------------------------------------------------------
-- Dimensão de data
-- ---------------------------------------------------------------------------
-- A chave e a própria data no formato AAAAMMDD. É legível na depuração e
-- evita uma junção só para descobrir de que dia e a linha do fato.
CREATE TABLE dw.dim_data (
    sk_data        integer PRIMARY KEY,
    data           date    NOT NULL UNIQUE,
    ano            smallint NOT NULL,
    trimestre      smallint NOT NULL,
    mes            smallint NOT NULL,
    dia            smallint NOT NULL,
    ano_mes        char(7)  NOT NULL,      -- 2025-03
    nome_mes       text     NOT NULL,
    nome_mes_curto char(3)  NOT NULL,
    dia_semana     smallint NOT NULL,      -- 1 = segunda
    nome_dia       text     NOT NULL,
    fim_de_semana  boolean  NOT NULL,
    semana_do_ano  smallint NOT NULL
);

-- ---------------------------------------------------------------------------
-- Dimensão de cliente: SCD tipo 2
-- ---------------------------------------------------------------------------
-- Quando um cliente muda de cidade ou de segmento, a linha antiga e
-- fechada e uma nova e aberta. Assim uma venda de 2024 continua ligada ao
-- segmento que o cliente tinha em 2024, e não ao de hoje.
CREATE TABLE dw.dim_cliente (
    sk_cliente  bigserial PRIMARY KEY,
    id_cliente  integer NOT NULL,          -- chave natural, vinda da origem
    nome        text    NOT NULL,
    cidade      text    NOT NULL,
    uf          char(2) NOT NULL,
    segmento    text    NOT NULL,
    valido_de   date    NOT NULL,
    valido_ate  date    NOT NULL DEFAULT DATE '9999-12-31',
    vigente     boolean NOT NULL DEFAULT true,
    versao      smallint NOT NULL DEFAULT 1
);

-- Garante que exista no máximo uma versão vigente por cliente. É a
-- proteção mais importante do SCD2: sem ela um erro de carga duplica as
-- linhas do fato silenciosamente.
CREATE UNIQUE INDEX idx_cliente_vigente
    ON dw.dim_cliente (id_cliente)
 WHERE vigente;

CREATE INDEX idx_cliente_natural ON dw.dim_cliente (id_cliente, valido_de);

-- ---------------------------------------------------------------------------
-- Dimensões de produto e loja: SCD tipo 1
-- ---------------------------------------------------------------------------
-- Aqui o histórico não interessa. Se o nome do produto foi corrigido, a
-- correção vale para trás também -- ninguém quer ver o nome errado num
-- relatório do ano passado.
CREATE TABLE dw.dim_produto (
    sk_produto    bigserial PRIMARY KEY,
    id_produto    integer UNIQUE NOT NULL,
    sku           text          NOT NULL,
    nome          text          NOT NULL,
    categoria     text          NOT NULL,
    subcategoria  text          NOT NULL,
    marca         text          NOT NULL,
    preco_lista   numeric(10,2) NOT NULL,
    custo         numeric(10,2) NOT NULL,
    atualizado_em timestamptz   NOT NULL DEFAULT now()
);

CREATE TABLE dw.dim_loja (
    sk_loja       bigserial PRIMARY KEY,
    id_loja       integer UNIQUE NOT NULL,
    codigo        text        NOT NULL,
    nome          text        NOT NULL,
    cidade        text        NOT NULL,
    uf            char(2)     NOT NULL,
    regiao        text        NOT NULL,
    tipo          text        NOT NULL,
    atualizado_em timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Fato
-- ---------------------------------------------------------------------------
-- Grao: um item dentro de um pedido. É o nível mais detalhado disponível na
-- origem, e deixar o grao no menor nível possível e a regra que evita ter
-- que refazer o modelo quando alguém pedir um corte novo.
CREATE TABLE dw.fato_venda (
    sk_venda      bigserial PRIMARY KEY,
    sk_data       integer NOT NULL REFERENCES dw.dim_data (sk_data),
    sk_cliente    bigint  NOT NULL REFERENCES dw.dim_cliente (sk_cliente),
    sk_produto    bigint  NOT NULL REFERENCES dw.dim_produto (sk_produto),
    sk_loja       bigint  NOT NULL REFERENCES dw.dim_loja (sk_loja),

    -- Chave natural guardada para reconciliação com a origem.
    id_pedido     integer  NOT NULL,
    numero_item   smallint NOT NULL,

    quantidade    integer       NOT NULL,
    valor_bruto   numeric(12,2) NOT NULL,
    desconto      numeric(12,2) NOT NULL,
    valor_liquido numeric(12,2) NOT NULL,
    custo_total   numeric(12,2) NOT NULL,
    margem        numeric(12,2) NOT NULL,

    UNIQUE (id_pedido, numero_item)
);

CREATE INDEX idx_fato_data ON dw.fato_venda (sk_data);
CREATE INDEX idx_fato_produto ON dw.fato_venda (sk_produto);
CREATE INDEX idx_fato_cliente ON dw.fato_venda (sk_cliente);
CREATE INDEX idx_fato_loja ON dw.fato_venda (sk_loja);
