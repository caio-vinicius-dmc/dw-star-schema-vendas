# dw-star-schema-vendas

Um armazém de dados de vendas montado do zero, pronto para ser conectado
no Power BI.

## Do que se trata, em linguagem simples

O sistema que registra as vendas é organizado para **gravar rápido**. Ele
espalha a informação em muitas tabelas pequenas, sem repetir nada: o nome
do cliente fica numa tabela, o pedido em outra, o item em outra.

Isso é ótimo para vender e péssimo para analisar. Quando alguém pergunta
"qual foi a margem por categoria no trimestre?", a resposta exige cruzar
cinco tabelas, e a consulta demora.

Um **data warehouse** é uma segunda cópia dos dados, organizada ao
contrário: pensada para responder perguntas rápido, mesmo repetindo
informação.

O formato mais usado se chama **esquema estrela**. No centro fica a tabela
dos fatos — cada item vendido, com quantidade e valor. Em volta ficam as
dimensões — quem comprou, o quê, onde e quando. O desenho lembra uma
estrela, daí o nome.

```
                    dim_data
                       │
    dim_cliente ─── fato_venda ─── dim_produto
                       │
                    dim_loja
```

Este projeto monta as três camadas de um ambiente de BI de verdade, dentro
de um único container:

| Camada | O que é |
|--------|---------|
| `origem` | o sistema de vendas simulado, normalizado, do jeito que chega |
| `dw` | o armazém: quatro dimensões e uma tabela de fatos |
| `bi` | a camada de consumo: consultas prontas, com nomes de negócio |

## O que você precisa ter instalado

- **Docker Desktop** —
  [docker.com](https://www.docker.com/products/docker-desktop/)
- **Python 3.11 ou mais novo** —
  [python.org](https://www.python.org/downloads/), marcando "Add Python to
  PATH".
- **Power BI Desktop**, só se quiser montar o relatório visual. É gratuito
  e roda no Windows.

## Como rodar

**1. Configuração e banco.**

```bash
cp .env.example .env
docker compose up -d
```

**2. Ambiente do Python.**

```bash
python -m venv .venv
.venv/Scripts/activate
pip install -r requirements.txt
```

No Linux ou macOS: `source .venv/bin/activate`.

**3. Agora os quatro comandos do fluxo.** O ciclo completo leva menos de
um minuto.

```bash
python -m src.cli migrar      # cria as três camadas
python -m src.cli semear      # gera 120 mil pedidos no sistema de origem
python -m src.cli carregar    # transforma a origem no armazém
python -m src.cli conferir    # confere se os números batem
```

**4. Veja o resultado.**

```bash
python -m src.cli resumo
```

### Quando terminar

```bash
docker compose down -v
```

## O que sai

Depois da carga:

| Tabela | Linhas |
|--------|--------|
| `dw.fato_venda` | 276.727 |
| `dw.dim_cliente` | 8.000 |
| `dw.dim_data` | 1.461 |
| `dw.dim_produto` | 600 |
| `dw.dim_loja` | 20 |

E o resumo mensal, já pronto para o relatório:

```
 Mês      | Pedidos | Itens  | Receita      | Margem % | Ticket médio
 2025-10  |   5.339 | 33.173 | 2.785.787,70 |     34,2 |       521,78
 2025-11  |   5.208 | 32.849 | 2.758.739,11 |     34,1 |       529,71
 2025-12  |   5.150 | 31.978 | 2.683.828,95 |     34,2 |       521,13
```

## A conferência, e por que ela existe

```bash
python -m src.cli conferir
```

```
linhas do fato x itens faturados na origem       276.727,00   276.727,00   ok
receita líquida total                         58.074.853,03  58.074.853,03  ok
clientes com mais de uma versão vigente                0,00         0,00   ok
linhas do fato sem dimensão correspondente             0,00         0,00   ok
dias com venda ausentes na dimensão de data            0,00         0,00   ok
itens com margem negativa                              0,00         0,00   ok
```

Isso não é enfeite. Na primeira vez que este projeto rodou, a carga
terminou **sem nenhum erro** e o armazém ficou com 225.433 linhas quando
deveria ter 276.727. Cinquenta e uma mil linhas sumiram em silêncio.

A causa: a geração criava clientes com data de cadastro até 2025, mas os
pedidos começavam em 2024. Um cliente cadastrado em março de 2025 com um
pedido em maio de 2024 não tinha nenhuma versão válida naquela data, e o
cruzamento simplesmente descartava a linha.

É o modo clássico de falha de um armazém de dados: nada quebra, nada
avisa, e o número do relatório fica 18% menor que o do sistema de origem.
Sem a conferência, isso só apareceria numa reunião.

O caso está contado em [docs/modelagem.md](docs/modelagem.md).

## Guardando o histórico do cliente

Um cliente que era "Varejo" em 2024 e virou "Corporativo" em 2026: as
vendas de 2024 devem contar como Varejo ou como Corporativo?

A resposta certa é Varejo — era o que ele era quando comprou. Um relatório
de 2024 não pode mudar porque alguém reclassificou o cliente hoje.

A técnica que resolve isso se chama **SCD tipo 2**: em vez de sobrescrever
o cadastro, o armazém fecha a versão antiga e abre uma nova. Para ver
funcionando:

```bash
python -m src.cli mudar-origem --clientes 50   # simula alterações no sistema
python -m src.cli carregar
```

Consultando o histórico:

```
 id_cliente | versão | segmento    | válido de  | válido até | vigente | vendas
          1 |      1 | Varejo      | 2023-05-23 | 2026-09-23 | não     |     14
          1 |      2 | Recorrente  | 2026-09-24 | 9999-12-31 | sim     |      0
```

As 14 vendas continuam na versão Varejo. Exatamente o que se quer.

Rodar `carregar` duas vezes seguidas sem alterar nada não cria versão nova
nem duplica o fato.

## A camada de consumo

Cinco consultas prontas, com nomes de negócio e sem chaves técnicas à
vista:

```sql
SELECT * FROM bi.vw_vendas;              -- uma linha por item, com tudo junto
SELECT * FROM bi.vw_resumo_mensal;       -- receita, margem e ticket por mês
SELECT * FROM bi.vw_margem_categoria;    -- margem por categoria
SELECT * FROM bi.vw_desempenho_loja;     -- desempenho por loja e região
SELECT * FROM bi.vw_historico_cliente;   -- as versões do cliente
```

Manter essa camada separada permite mudar a estrutura interna do armazém
sem quebrar o relatório de ninguém — desde que as consultas continuem
devolvendo as mesmas colunas.

## Conectando no Power BI

O arquivo `.pbix` **não está** neste repositório, e isso é proposital: é
um formato binário fechado, que não dá para revisar nem versionar direito,
e que qualquer pessoa monta em dez minutos.

O que está aqui é o que realmente importa e costuma faltar:

- **[powerbi/medidas.dax](powerbi/medidas.dax)** — 25 medidas prontas e
  comentadas: receita, margem, ticket médio, variação contra o mês e
  contra o ano anterior, acumulado do ano, média móvel, participação e
  ranking.
- **[docs/power-bi.md](docs/power-bi.md)** — o passo a passo: criar o
  usuário somente leitura, conectar, montar os relacionamentos, e o erro
  mais comum (esquecer de marcar a tabela de datas, o que faz toda
  variação aparecer como zero sem dar erro nenhum).

O mesmo banco atende Qlik, Metabase ou qualquer ferramenta que fale
PostgreSQL. Só as medidas em DAX são específicas do Power BI.

## Estrutura das pastas

```
sql/01_origem.sql            o sistema de vendas simulado
sql/02_modelo.sql            as dimensões e a tabela de fatos
sql/03_views.sql             a camada de consumo
sql/10_semear_origem.sql     a geração dos dados
sql/20_carga_dimensoes.sql   a carga das dimensões, com o histórico de cliente
sql/21_carga_fato.sql        a carga dos fatos
sql/30_conferencia.sql       a conferência contra a origem
powerbi/medidas.dax          as medidas prontas
docs/                        a modelagem e o guia do Power BI
```

Quase toda a lógica está em SQL. O Python conecta, executa na ordem certa
e formata o resultado — transformação de dados dentro do banco evita
trafegar milhões de linhas pela rede só para devolvê-las alteradas.

## Problemas comuns

**"ports are not available" ou "bind: An attempt was made to access a socket
in a way forbidden by its access permissions".** O Windows reserva faixas de
porta para uso próprio, e elas mudam a cada reinício. Veja quais estão
reservadas com:

```bash
netsh int ipv4 show excludedportrange protocol=tcp
```

Se a porta do projeto estiver numa das faixas, mude `POSTGRES_PORT` no
arquivo `.env` para qualquer valor livre abaixo de 49152 e suba de novo.

**"O banco recusou a senha."** Você mudou a senha no `.env` depois de já
ter subido o banco. Recrie com `docker compose down -v && docker compose up -d`.

**A conferência acusa divergência.** É o comportamento esperado quando
algo deu errado. A primeira linha da tabela mostra qual verificação
falhou; o motivo mais comum está explicado em
[docs/modelagem.md](docs/modelagem.md).

**No Power BI, toda variação aparece como zero.** Faltou marcar
`dim_data` como tabela de datas. Esse passo é obrigatório e é o mais
esquecido — sem ele as funções de comparação entre períodos não dão erro,
apenas devolvem o valor do período atual.

## Limitações

- A carga dos fatos reprocessa tudo a cada execução. É aceitável com 277
  mil linhas; um armazém de verdade processaria apenas o período alterado.
- Não há uma linha "desconhecido" nas dimensões. Uma venda cujo cliente
  não tenha versão válida na data some da carga. A conferência pega, mas o
  certo seria direcioná-la para uma linha padrão.
- Sem particionamento e sem tabelas pré-somadas. Os dois começariam a
  fazer sentido a partir de algumas dezenas de milhões de linhas.
- Sem agendamento. A carga é disparada à mão ou por um orquestrador
  externo — é o que o [airflow-pipeline](../airflow-pipeline) cobre.

---

## 👤 Autor

Desenvolvido por **Caio Vinícius Barbosa Barros**.

Se você tiver dúvidas, sugestões ou quiser reportar um problema, sinta-se à vontade para entrar em contato:

*   **✉️ E-mail:** [caio@dynamicmotioncentury.com.br](mailto:caio@dynamicmotioncentury.com.br)
*   **🌐 Site/Portfólio:** [www.dynamicmotioncentury.com.br](https://dynamicmotioncentury.com.br)
*   **💼 LinkedIn:** [linkedin.com/in/caio-vinicius-dmc](https://linkedin.com/in/caio-vinicius-dmc)
*   **🐙 GitHub:** [@caio-vinicius-dmc](https://github.com/caio-vinicius-dmc)

💡 *Se este projeto te ajudou, deixe uma ⭐ no repositório!*
