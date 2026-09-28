# Conectando o Power BI a este modelo

Este projeto entrega o backend de BI: o modelo dimensional, a camada de
consumo e as medidas. O arquivo `.pbix` em si não está aqui -- é um binário
proprietário que não faz sentido versionar, e qualquer pessoa consegue
montá-lo em dez minutos seguindo o que está abaixo.

## Antes de conectar

Crie um usuário somente leitura. O Power BI nunca precisa escrever no DW, e
um desktop com credencial de escrita é um acidente esperando para acontecer:

```sql
CREATE USER powerbi_leitura WITH PASSWORD 'defina_uma_senha_forte';
GRANT CONNECT ON DATABASE vendas_dw TO powerbi_leitura;
GRANT USAGE ON SCHEMA bi, dw TO powerbi_leitura;
GRANT SELECT ON ALL TABLES IN SCHEMA bi, dw TO powerbi_leitura;
ALTER DEFAULT PRIVILEGES IN SCHEMA bi, dw
    GRANT SELECT ON TABLES TO powerbi_leitura;
```

A senha não entra em arquivo versionado. No Power BI Desktop ela fica no
gerenciador de credenciais; no Power BI Service, na configuração do gateway.

## Conexão

1. **Obter dados** > **Banco de dados PostgreSQL**
2. Servidor: `localhost:15434` (a porta do `docker-compose.yml`)
3. Banco de dados: `vendas_dw`
4. Modo: **Importar**

Sobre o modo: **Importar** é a escolha certa aqui. DirectQuery só compensa
quando o volume não cabe em memória ou quando o relatório precisa refletir a
última transação; este modelo tem 277 mil linhas de fato, cabe em memória
sem esforco, e importar deixa o relatório muito mais rápido.

O conector do PostgreSQL pede o Npgsql instalado. Versões recentes do Power
BI Desktop já o trazem embutido.

## Duas formas de montar o modelo

### Caminho curto: uma view só

Importe apenas `bi.vw_vendas`. Ela já traz o fato junto com todos os
atributos das dimensões, então não há relacionamento a configurar.

Serve para prototipo e para relatório pequeno. A desvantagem aparece
depois: sem tabela de datas própria, nenhuma função de inteligência de
tempo funciona direito, e o modelo em tabela única ocupa muito mais memória
porque repete os textos das dimensões em cada linha.

### Caminho recomendado: esquema estrela no próprio Power BI

Importe cinco tabelas:

| Tabela | Papel |
|--------|-------|
| `dw.fato_venda` | fato |
| `dw.dim_data` | dimensão de data |
| `dw.dim_cliente` | dimensão (com versões do SCD2) |
| `dw.dim_produto` | dimensão |
| `dw.dim_loja` | dimensão |

Relacionamentos, todos **um para muitos** com direção **simples**, da
dimensão para o fato:

```
dim_data[sk_data]       1 -> *  fato_venda[sk_data]
dim_cliente[sk_cliente] 1 -> *  fato_venda[sk_cliente]
dim_produto[sk_produto] 1 -> *  fato_venda[sk_produto]
dim_loja[sk_loja]       1 -> *  fato_venda[sk_loja]
```

Filtro cruzado bidirecional parece conveniente mas cria ambiguidade assim
que o modelo cresce. Deixe simples e resolva os casos específicos com
`CROSSFILTER` dentro da medida que precisar.

## Marcar a tabela de datas

Este passo e obrigatório e e o mais esquecido.

Selecione `dim_data` > **Marcar como tabela de data** > coluna `data`.

Sem isso, `SAMEPERIODLASTYEAR`, `TOTALYTD` e `DATEADD` não acusam erro --
elas simplesmente devolvem o valor do período atual, e o relatório mostra
variação de 0% em tudo. É um problema silencioso e chato de achar.

Depois de marcar, esconda a coluna `sk_data` da visualização. Ela é uma
chave técnica e não deve aparecer para quem monta o relatório.

## Medidas

O arquivo [`powerbi/medidas.dax`](../powerbi/medidas.dax) traz as medidas
prontas, agrupadas em base, derivadas, inteligência de tempo e
participação.

O Power BI não importa `.dax` em lote: cada medida entra por **Nova
medida**, colando o corpo. O arquivo existe para que a definição tenha um
lugar único e versionado -- quando a regra de margem mudar, ela muda aqui
antes de mudar no relatório de alguém.

Sugestão de organização: crie uma tabela vazia chamada `_Medidas` (Inserir
dados > tabela em branco) e mova todas as medidas para ela. O painel de
campos fica muito mais limpo do que com as medidas espalhadas pelas
tabelas.

## Sobre o SCD2 no relatório

`dim_cliente` tem mais de uma linha por cliente quando ele mudou de
segmento ou cidade. Isso é proposital, mas confunde quem monta o relatório
sem saber.

- Para **contar clientes distintos**, use `id_cliente`, nunca `sk_cliente`.
  Um cliente com duas versões contaria duas vezes.
- Para **analisar como as coisas eram na epoca da venda**, use os atributos
  da dimensão normalmente. O fato já aponta para a versão correta.
- Para **analisar pela situação atual**, filtre `vigente = true` -- mas
  atenção: isso descarta as vendas ligadas a versões antigas.

A view `bi.vw_historico_cliente` mostra as duas versões lado a lado com a
receita de cada uma. É o jeito mais rápido de explicar o conceito para
quem nunca viu.

## Atualização

Em ambiente local, atualizar e reimportar no Desktop. Em ambiente
compartilhado seria preciso um gateway de dados local, porque o Power BI
Service não alcanca um PostgreSQL em rede privada.

O ETL deste projeto não tem agendador -- ele e disparado a mão ou por um
orquestrador externo. A ordem correta é sempre: carregar o DW primeiro,
atualizar o relatório depois.

## Qlik, Metabase e outros

O mesmo schema `bi` atende qualquer ferramenta que fale PostgreSQL. A parte
específica do Power BI e o DAX; a modelagem, as views e o usuário somente
leitura valem igual.

No Qlik Sense o caminho é o mesmo esquema estrela, com as expressões
reescritas em sintaxe Qlik -- `Sum(valor_liquido)` no lugar de
`SUM ( fato_venda[valor_liquido] )`.
