// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

pragma solidity 0.5.12;

contract ERC20 {
    function balanceOf(address whom) external view returns (uint);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address dst, uint amt) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

contract BPool is ERC20 {
    function isBound(address t) external view returns (bool);
    function getBalance(address token) external view returns (uint);
    function setSwapFee(uint swapFee) external;
    function setController(address controller) external;
    function setPublicSwap(bool public_) external;
    function finalize() external;
    function bind(address token, uint balance, uint denorm) external;
    function rebind(address token, uint balance, uint denorm) external;
    function unbind(address token) external;
}

contract BFactory {
    function newBPool() external returns (BPool);
}

contract BActions {

    function create(
        BFactory factory,
        address[] calldata tokens,
        uint[] calldata balances,
        uint[] calldata denorms,
        uint swapFee,
        bool finalize
    ) external returns (BPool pool) {
        require(tokens.length == balances.length, "ERR_LENGTH_MISMATCH");
        require(tokens.length == denorms.length, "ERR_LENGTH_MISMATCH");

        pool = factory.newBPool();
        pool.setSwapFee(swapFee);

        for (uint8 i = 0; i < tokens.length; i++) {
            ERC20 token = ERC20(tokens[i]);
            token.transferFrom(msg.sender, address(this), balances[i]);
            token.approve(address(pool), balances[i]);
            pool.bind(tokens[i], balances[i], denorms[i]);
        }

        if (finalize) {
            pool.finalize();
            pool.transfer(msg.sender, pool.balanceOf(address(this)));
        } else {
            pool.setController(address(this));
            pool.setPublicSwap(true);
        }
    }

    function rebind(
        BPool pool,
        address[] calldata tokens,
        uint[] calldata balances,
        uint[] calldata denorms
    ) external {
        require(tokens.length == balances.length, "ERR_LENGTH_MISMATCH");
        require(tokens.length == denorms.length, "ERR_LENGTH_MISMATCH");

        for (uint8 i = 0; i < tokens.length; i++) {
            ERC20 token = ERC20(tokens[i]);
            if (pool.isBound(tokens[i])) {
                if (balances[i] > pool.getBalance(tokens[i])) {
                    token.transferFrom(msg.sender, address(this), balances[i] - pool.getBalance(tokens[i]));
                    token.approve(address(pool), balances[i] - pool.getBalance(tokens[i]));
                }
                if (balances[i] > 0) {
                    pool.rebind(tokens[i], balances[i], denorms[i]);
                } else {
                    pool.unbind(tokens[i]);
                }

                if (token.balanceOf(address(this)) > 0) {
                    token.transfer(msg.sender, token.balanceOf(address(this)));
                }
            } else {
                token.transferFrom(msg.sender, address(this), balances[i]);
                token.approve(address(pool), balances[i]);
                pool.bind(tokens[i], balances[i], denorms[i]);
            }

        }
    }

    function setPublicSwap(BPool pool, bool publicSwap) external {
        pool.setPublicSwap(publicSwap);
    }

    function setSwapFee(BPool pool, uint256 newFee) external {
        pool.setSwapFee(newFee);
    }

    function setController(BPool pool, address newController) external {
        pool.setController(newController);
    }

    function finalize(BPool pool) external {
        pool.finalize();
        pool.transfer(msg.sender, pool.balanceOf(address(this)));
    }
}