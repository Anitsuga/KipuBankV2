
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/*///////////////////////
        Imports
///////////////////////*/
/// @notice Propietario con control de acceso básico (soloOwner)
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
/// @notice Librería de utilidades seguras para transferencias ERC20
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
/// @notice Interfaz ERC20 estándar
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
/// @notice Interfaz de Chainlink para feeds de precios (v3)
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title KipuBankV2
 * @notice Bóveda que acepta depósitos y retiros en ETH y USDC con límites globales/por transacción expresados en USD (6 decimales).
 * @dev Usa Chainlink ETH/USD para convertir montos de ETH a USD(6). Para USDC, su unidad nativa ya es 6 decimales.
 * @custom:security Contrato educativo. No usar en producción sin auditoría profesional.
 */
contract KipuBankV2 is Ownable {
    /*///////////////////////
      Declaración de tipos
    ///////////////////////*/
    /// @notice Habilita el uso de funciones seguras de transferencia/aprobación para IERC20
    using SafeERC20 for IERC20;

    /*///////////////////////
           Constantes
    ///////////////////////*/
    /// @notice Heartbeat máximo tolerado del oráculo (segundos). Si el precio es más viejo → precio obsoleto.
    uint16 public constant ORACLE_HEARTBEAT = 3600; // 1 hora

    /// @notice Factor de decimales: 10^20 (= 10^(18 ETH + 8 price - 6 USD)), normaliza ETH(18) * price(8) → USD(6)
    uint256 public constant DECIMAL_FACTOR = 1e20;

    /// @notice Decimales objetivo para USD estilo USDC (6)
    uint8 public constant DECIMALS_USDC = 6;

    /*///////////////////////
           Variables
    ///////////////////////*/
    /// @notice Referencia al token USDC (decimales nativos = 6)
    IERC20 public immutable i_usdc;

    /// @notice Feed Chainlink ETH/USD usado para convertir ETH→USD(6)
    AggregatorV3Interface public immutable i_ethUsdFeed;

    /// @notice Límite global del banco en USD(6). Si se excede al depositar, se revierte.
    uint256 public immutable i_bankCapUSD6;

    /// @notice Límite máximo por retiro en USD(6). Aplica tanto a ETH (valorado en USD) como a USDC.
    uint256 public immutable i_withdrawLimitUSD6;

    /// @notice Balance interno de ETH por usuario (en wei)
    mapping(address usuario => uint256 balanceWei) public s_ethBalances;

    /// @notice Balance interno de USDC por usuario (en unidades de 6 decimales)
    mapping(address usuario => uint256 balanceUSDC) public s_usdcBalances;

    /// @notice Cantidad de depósitos realizados por usuario (conteo)
    mapping(address usuario => uint256 count) public s_depositCount;

    /// @notice Cantidad de retiros realizados por usuario (conteo)
    mapping(address usuario => uint256 count) public s_withdrawCount;

    /// @notice Conteo global de depósitos (no USD)
    uint256 public s_totalDeposits;

    /// @notice Conteo global de retiros (no USD)
    uint256 public s_totalWithdrawals;

    /// @notice Valor total del banco en USD(6). Suma de ETH valuado en USD(6) + USDC.
    uint256 public s_totalUSD6;

    /// @notice Flag de reentrancia: true si una función protegida está en ejecución
    bool private s_locked;

    /// @notice Flag de pausa: true detiene depósitos y retiros
    bool public s_paused;

    /*///////////////////////
           Eventos
    ///////////////////////*/
    /// @notice Evento emitido al depositar ETH
    /// @param usuario Dirección que deposita
    /// @param amountETH Monto de ETH depositado (wei)
    /// @param usd6 Valor equivalente en USD(6) calculado con Chainlink
    event KipuBankV2_DepositoETH(address indexed usuario, uint256 amountETH, uint256 usd6);

    /// @notice Evento emitido al depositar USDC
    /// @param usuario Dirección que deposita
    /// @param amountUSDC Monto depositado en USDC (6 decimales)
    event KipuBankV2_DepositoUSDC(address indexed usuario, uint256 amountUSDC);

    /// @notice Evento emitido al retirar ETH
    /// @param usuario Dirección que retira
    /// @param amountETH Monto retirado (wei)
    /// @param usd6 Valor equivalente en USD(6) usado para validar límite por transacción
    event KipuBankV2_ExtraccionETH(address indexed usuario, uint256 amountETH, uint256 usd6);

    /// @notice Evento emitido al retirar USDC
    /// @param usuario Dirección que retira
    /// @param amountUSDC Monto retirado (6 decimales)
    event KipuBankV2_ExtraccionUSDC(address indexed usuario, uint256 amountUSDC);

    /// @notice Evento emitido al pausar o reanudar el contrato
    /// @param estado Nuevo estado de pausa
    event KipuBankV2_PausaCambiada(bool estado);

    /*///////////////////////
            Errores
    ///////////////////////*/
    /// @notice Error: reentrada detectada al usar funciones protegidas
    error KipuBankV2_Reentrancia();

    /// @notice Error: el contrato está en pausa
    error KipuBankV2_Pausado();

    /// @notice Error: el monto provisto es cero
    error KipuBankV2_MontoCero();

    /// @notice Error: precio del oráculo no válido (<= 0)
    error KipuBankV2_OracleComprometido();

    /// @notice Error: precio del oráculo obsoleto (stale) respecto al heartbeat configurado
    error KipuBankV2_StalePrice();

    /// @notice Error: se excede el límite global del banco en USD(6)
    /// @param total Nuevo total en USD(6) que se intentó alcanzar
    /// @param limite Límite global configurado en USD(6)
    error KipuBankV2_LimiteGlobalSuperado(uint256 total, uint256 limite);

    /// @notice Error: se excede el límite por transacción en USD(6)
    /// @param solicitado Monto requerido en USD(6)
    /// @param maximo Límite por transacción en USD(6)
    error KipuBankV2_LimiteExtraccion(uint256 solicitado, uint256 maximo);

    /// @notice Error: el balance del usuario es insuficiente
    /// @param solicitado: Monto solicitado en la divisa del activo
    /// @param disponible: Balance disponible del usuario en el activo
    error KipuBankV2_SaldoInsuficiente(uint256 solicitado, uint256 disponible);

    /// @notice Error: transferencia nativa fallida
    /// @param razon: Datos de error devueltos por la llamada
    error KipuBankV2_TransferenciaFallida(bytes razon);

    /*///////////////////////
          Modificadores
    ///////////////////////*/
    /// @notice Protege contra ataques de reentrancia
    modifier nonReentrant() {
        if (s_locked) revert KipuBankV2_Reentrancia();
        s_locked = true;
        _;
        s_locked = false;
    }

    /// @notice Permite ejecutar solo cuando el contrato no está en pausa
    modifier whenNotPaused() {
        if (s_paused) revert KipuBankV2_Pausado();
        _;
    }

    /// @notice Verifica que el monto sea > 0
    /// @param amount: Monto a validar
    modifier montoValido(uint256 amount) {
        if (amount == 0) revert KipuBankV2_MontoCero();
        _;
    }

    /*///////////////////////
          Constructor
    ///////////////////////*/
    /**
     * @notice Inicializa la bóveda con sus dependencias y límites.
     * @param _owner: Dirección del propietario (para Ownable)
     * @param _usdc: Dirección del contrato USDC (ERC20 con 6 decimales)
     * @param _ethUsdFeed: Dirección del Chainlink ETH/USD feed (de la red usada)
     * @param _bankCapUSD6: Límite global del banco en USD con 6 decimales
     * @param _withdrawLimitUSD6: Límite máximo por retiro en USD con 6 decimales
     */
    constructor(
        address _owner,
        address _usdc,
        address _ethUsdFeed,
        uint256 _bankCapUSD6,
        uint256 _withdrawLimitUSD6
    ) Ownable(_owner) {
        /// @dev Guarda referencia a USDC (se asume token confiable de 6 decimales)
        i_usdc = IERC20(_usdc);

        /// @dev Guarda referencia al feed ETH/USD de Chainlink
        i_ethUsdFeed = AggregatorV3Interface(_ethUsdFeed);

        /// @dev Límite global del banco en USD(6)
        i_bankCapUSD6 = _bankCapUSD6;

        /// @dev Límite por transacción en USD(6)
        i_withdrawLimitUSD6 = _withdrawLimitUSD6;

        /// @dev Inicializa guard de reentrancia en “desbloqueado”
        s_locked = false;
    }

    /*///////////////////////
        Funciones admin
    ///////////////////////*/
    /**
     * @notice Pausa o reanuda depósitos y retiros.
     * @param _status true para pausar, false para reanudar
     * @dev Solo ejecutable por el propietario.
     */
    function setPaused(bool _status) external onlyOwner {
        s_paused = _status;
        emit KipuBankV2_PausaCambiada(_status);
    }

    /*///////////////////////
           Depósitos
    ///////////////////////*/
    /**
     * @notice Deposita ETH en la bóveda y lo contabiliza en USD(6) con Chainlink.
     * @dev Aplica validaciones de pausa, monto > 0, límite global y reentrancia.
     * @custom:interaction No transfiere a terceros; solo incrementa estado interno.
     */
    function depositETH()
        external
        payable
        whenNotPaused
        nonReentrant
        montoValido(msg.value)
    {
        // Convertir a USD(6) usando feed
        uint256 usd6 = _ethToUSD6(msg.value);

        // Verificar bank cap (límite global)
        uint256 nuevoTotal = s_totalUSD6 + usd6;
        if (nuevoTotal > i_bankCapUSD6) revert KipuBankV2_LimiteGlobalSuperado(nuevoTotal, i_bankCapUSD6);

        // Effects
        s_totalUSD6 = nuevoTotal;
        s_ethBalances[msg.sender] += msg.value;
        s_depositCount[msg.sender] += 1;
        s_totalDeposits += 1;

        // Evento
        emit KipuBankV2_DepositoETH(msg.sender, msg.value, usd6);
    }

    /**
     * @notice Deposita USDC en la bóveda (USDC ya está en USD(6)).
     * @param amount: Cantidad de USDC a depositar (6 decimales)
     * @dev Requiere aprobación previa (approve) al contrato. Valida pausa, monto y bank cap.
     */
    function depositUSDC(uint256 amount)
        external
        whenNotPaused
        nonReentrant
        montoValido(amount)
    {
        // Verificar bank cap con USDC directamente (ya está en 6 decimales)
        uint256 nuevoTotal = s_totalUSD6 + amount;
        if (nuevoTotal > i_bankCapUSD6) revert KipuBankV2_LimiteGlobalSuperado(nuevoTotal, i_bankCapUSD6);

        // Interactions: transferir USDC desde el usuario al contrato (pull)
        i_usdc.safeTransferFrom(msg.sender, address(this), amount);

        // Effects
        s_totalUSD6 = nuevoTotal;
        s_usdcBalances[msg.sender] += amount;
        s_depositCount[msg.sender] += 1;
        s_totalDeposits += 1;

        // Evento
        emit KipuBankV2_DepositoUSDC(msg.sender, amount);
    }

    /*///////////////////////
            Retiros
    ///////////////////////*/
    /**
     * @notice Retira ETH de la bóveda del llamador, validando su equivalente en USD(6) contra el límite por transacción.
     * @param amount: Cantidad de ETH a retirar (wei)
     * @dev Aplica CEI, nonReentrant, pausa, y valida límites y saldos.
     */
    function withdrawETH(uint256 amount)
        external
        whenNotPaused
        nonReentrant
        montoValido(amount)
    {
        // Checks: saldo suficiente
        uint256 balance = s_ethBalances[msg.sender];
        if (amount > balance) revert KipuBankV2_SaldoInsuficiente(amount, balance);

        // Checks: límite por transacción en USD(6)
        uint256 usd6 = _ethToUSD6(amount);
        if (usd6 > i_withdrawLimitUSD6) revert KipuBankV2_LimiteExtraccion(usd6, i_withdrawLimitUSD6);

        // Effects
        unchecked {
            s_ethBalances[msg.sender] = balance - amount;
            s_totalUSD6 -= usd6;
        }
        s_withdrawCount[msg.sender] += 1;
        s_totalWithdrawals += 1;

        // Interactions: envío nativo seguro
        (bool success, bytes memory reason) = payable(msg.sender).call{value: amount}("");
        if (!success) revert KipuBankV2_TransferenciaFallida(reason);

        // Evento
        emit KipuBankV2_ExtraccionETH(msg.sender, amount, usd6);
    }

    /**
     * @notice Retira USDC de la bóveda del llamador, validando límite por transacción (en USD(6)).
     * @param amount: Cantidad de USDC a retirar (6 decimales)
     * @dev Para USDC el límite se compara directo, ya que su unidad nativa es USD(6).
     */
    function withdrawUSDC(uint256 amount)
        external
        whenNotPaused
        nonReentrant
        montoValido(amount)
    {
        // Checks: saldo suficiente
        uint256 balance = s_usdcBalances[msg.sender];
        if (amount > balance) revert KipuBankV2_SaldoInsuficiente(amount, balance);

        // Checks: límite por transacción (USDC ya está en USD(6))
        if (amount > i_withdrawLimitUSD6) revert KipuBankV2_LimiteExtraccion(amount, i_withdrawLimitUSD6);

        // Effects
        unchecked {
            s_usdcBalances[msg.sender] = balance - amount;
            s_totalUSD6 -= amount;
        }
        s_withdrawCount[msg.sender] += 1;
        s_totalWithdrawals += 1;

        // Interactions
        i_usdc.safeTransfer(msg.sender, amount);

        // Evento
        emit KipuBankV2_ExtraccionUSDC(msg.sender, amount);
    }

    /*///////////////////////
       Conversión ETH→USD6
    ///////////////////////*/
    /**
     * @notice Convierte un monto en ETH (wei) a USD(6) usando Chainlink ETH/USD.
     * @param amountETH: Monto en wei a convertir.
     * @return usd6 Monto equivalente en USD con 6 decimales.
     * @dev Valida que el precio sea positivo y no obsoleto. Usa DECIMAL_FACTOR=1e20 para normalizar.
     */
    function _ethToUSD6(uint256 amountETH) internal view returns (uint256 usd6) {
        // Obtener datos del feed (roundId ignorado)
        (, int256 price, , uint256 updatedAt, ) = i_ethUsdFeed.latestRoundData();

        // Validaciones de seguridad del oráculo
        if (price <= 0) revert KipuBankV2_OracleComprometido();
        if (block.timestamp - updatedAt > ORACLE_HEARTBEAT) revert KipuBankV2_StalePrice();

        // amountETH(1e18) * price(1e8) / 1e20 = USD(1e6)
        usd6 = (amountETH * uint256(price)) / DECIMAL_FACTOR;
    }

    /*///////////////////////
        Funciones de vista
    ///////////////////////*/
    /**
     * @notice Devuelve el balance de ETH del usuario (en wei).
     * @param user: Dirección del usuario.
     * @return balanceWei Balance en wei.
     */
    function getEthBalance(address user) external view returns (uint256 balanceWei) {
        return s_ethBalances[user];
    }

    /**
     * @notice Devuelve el balance de USDC del usuario (6 decimales).
     * @param user: Dirección del usuario.
     * @return balanceUSDC Balance en unidades de 6 decimales.
     */
    function getUsdcBalance(address user) external view returns (uint256 balanceUSDC) {
        return s_usdcBalances[user];
    }

    /**
     * @notice Devuelve el balance nativo de ETH que posee el contrato (en wei).
     * @return balanceETH Balance en wei.
     */
    function contractBalanceETH() external view returns (uint256 balanceETH) {
        return address(this).balance;
    }

    /**
     * @notice Devuelve el balance de USDC que posee el contrato (6 decimales).
     * @return balanceUSDC Balance en unidades de 6 decimales.
     */
    function contractBalanceUSDC() external view returns (uint256 balanceUSDC) {
        return i_usdc.balanceOf(address(this));
    }

    /*///////////////////////
         Receive/Fallback
    ///////////////////////*/
    /// @notice Evita recibir ETH sin pasar por la función de depósito (para no saltar validaciones)
    receive() external payable {
        revert("Usar depositETH()");
    }

    /// @notice Rechaza llamadas a funciones inexistentes
    fallback() external payable {
        revert();
    }
}
